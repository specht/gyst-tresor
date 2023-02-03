require "base64"
require "digest"
require "json"
require "jwt"
require "mail"
require "neo4j_bolt"
require 'prawn/qrcode'
require 'prawn/measurement_extensions'
require 'prawn-styled-text'
require "sinatra/base"
require "sinatra/cookies"
require 'curl'

Neo4jBolt.bolt_host = 'neo4j'
Neo4jBolt.bolt_port = 7687

require "./credentials.template.rb"
warn_level = $VERBOSE
$VERBOSE = nil
require "./credentials.rb"
$VERBOSE = warn_level
DASHBOARD_SERVICE = ENV["DASHBOARD_SERVICE"]

class Prawn::Document
    def elide_string(s, width, style = {}, suffix = '…')
        return '' if width <= 0
        return s if width_of(s, style) <= width
        suffix_width = width_of(suffix, style)
        width -= suffix_width
        length = s.size
        i = 0
        l = s.size
        r = l
        while width_of(s[0, l], style) > width
            r = l
            l /= 2
        end
        i = 0
        while l < r - 1 do
            m = (l + r) / 2
            if width_of(s[0, m], style) > width
                r = m
            else
                l = m
            end
            i += 1
            break if (i > 1000)
        end
        s[0, l].strip + suffix
    end
end

def debug(message, index = 0)
    index = 0
    begin
        while index < caller_locations.size - 1 && ["transaction", "neo4j_query", "neo4j_query_expect_one"].include?(caller_locations[index].base_label)
            index += 1
        end
    rescue
        index = 0
    end
    l = caller_locations[index]
    ls = ""
    begin
        ls = "#{l.path.sub("/app/", "")}:#{l.lineno} @ #{l.base_label}"
    rescue
        ls = "#{l[0].sub("/app/", "")}:#{l[1]}"
    end
    STDERR.puts "#{DateTime.now.strftime("%H:%M:%S")} [#{ls}] #{message}"
end

def debug_error(message)
    l = caller_locations.first
    ls = ""
    begin
        ls = "#{l.path.sub("/app/", "")}:#{l.lineno} @ #{l.base_label}"
    rescue
        ls = "#{l[0].sub("/app/", "")}:#{l[1]}"
    end
    STDERR.puts "#{DateTime.now.strftime("%H:%M:%S")} [ERROR] [#{ls}] #{message}"
end

def fix_h_to_hh(s)
    return nil if s.nil?
    if s =~ /^\d:\d\d$/
        "0" + s
    else
        s
    end
end

class Neo4jGlobal
    include Neo4jBolt
end

$neo4j = Neo4jGlobal.new

class RandomTag
    BASE_31_ALPHABET = "0123456789bcdfghjklmnpqrstvwxyz"
    def self.to_base31(i)
        result = ""
        while i > 0
            result += BASE_31_ALPHABET[i % 31]
            i /= 31
        end
        result
    end

    def self.generate(length = 12)
        self.to_base31(SecureRandom.hex(length).to_i(16))[0, length]
    end
end

def join_with_sep(list, a, b)
    list.size == 1 ? list.first : [list[0, list.size - 1].join(a), list.last].join(b)
end

class SetupDatabase
    include Neo4jBolt

    CONSTRAINTS_LIST = [
        'Entry/tag',
        'User/email',
    ]

    INDEX_LIST = [
    ]

    def setup(main)
        wait_for_neo4j
        delay = 1
        10.times do
            begin
                neo4j_query("MATCH (n) RETURN n LIMIT 1;")
                break unless ENV['SERVICE'] == 'ruby'
                setup_constraints_and_indexes(CONSTRAINTS_LIST, INDEX_LIST)
                debug "Setup finished."
                break
            rescue
                debug $!
                debug "Retrying setup after #{delay} seconds..."
                sleep delay
                delay += 1
            end
        end
    end
end

class Main < Sinatra::Base
    include Neo4jBolt
    helpers Sinatra::Cookies

    configure do
        set :show_exceptions, false
    end

    def self.collect_data
        $neo4j.wait_for_neo4j
        @@cache = {}
        $neo4j.neo4j_query("MATCH (e:Entry) RETURN e.tag, e.value") do |row|
            @@cache[row['e.tag']] = row['e.value']
        end
    end

    def query_dashboard(path)
        url = "#{'https://dashboard.gymnasiumsteglitz.de'}#{path}"
        debug url
        res = Curl.get(url) do |http|
            payload = {:exp => Time.now.to_i + 60}
            http.headers['X-JWT'] = JWT.encode(payload, JWT_APPKEY_TRESOR, "HS256")
        end
        assert(res.response_code == 200)
        return JSON.parse(res.body)
    end

    configure do
        self.collect_data() unless defined?(SKIP_COLLECT_DATA) && SKIP_COLLECT_DATA
        if ENV["SERVICE"] == "ruby" && (File.basename($0) == "thin" || File.basename($0) == "pry.rb")
            setup = SetupDatabase.new()
            setup.setup(self)
        end
        @@dashboard_etag = nil
        @@bib_label_print_queue = []
        if ["thin", "rackup"].include?(File.basename($0))
            debug("Server is up and running!")
        end
        if ENV["SERVICE"] == "ruby" && File.basename($0) == "pry.rb"
            binding.pry
        end
    end

    def assert(condition, message = "assertion failed", suppress_backtrace = false, delay = nil)
        unless condition
            debug_error message
            e = StandardError.new(message)
            e.set_backtrace([]) if suppress_backtrace
            sleep delay unless delay.nil?
            raise e
        end
    end

    def assert_with_delay(condition, message = "assertion failed", suppress_backtrace = false)
        assert(condition, message, suppress_backtrace, 3.0)
    end

    def test_request_parameter(data, key, options)
        type = ((options[:types] || {})[key]) || String
        assert(data[key.to_s].is_a?(type), "#{key.to_s} is a #{type} (it's a #{data[key.to_s].class})")
        if type == String
            assert(data[key.to_s].size <= (options[:max_value_lengths][key] || options[:max_string_length]), "too_much_data")
        end
    end

    def parse_request_data(options = {})
        options[:max_body_length] ||= 512
        options[:max_string_length] ||= 512
        options[:required_keys] ||= []
        options[:optional_keys] ||= []
        options[:max_value_lengths] ||= {}
        data_str = request.body.read(options[:max_body_length]).to_s
        # debug data_str
        @latest_request_body = data_str.dup
        begin
            assert(data_str.is_a? String)
            assert(data_str.size < options[:max_body_length], "too_much_data")
            data = JSON::parse(data_str)
            @latest_request_body_parsed = data.dup
            result = {}
            options[:required_keys].each do |key|
                assert(data.include?(key.to_s), "missing key: #{key}")
                test_request_parameter(data, key, options)
                result[key.to_sym] = data[key.to_s]
            end
            options[:optional_keys].each do |key|
                if data.include?(key.to_s)
                    test_request_parameter(data, key, options)
                    result[key.to_sym] = data[key.to_s]
                end
            end
            result
        rescue
            debug "Request was:"
            debug data_str
            raise
        end
    end

    before "*" do
        if DEVELOPMENT
            response.headers["Access-Control-Allow-Origin"] = "http://localhost:8025"
        else
            if request.path[0, 5] == "/jwt/" || request.path[0, 8] == '/public/'
                response.headers["Access-Control-Allow-Origin"] = "https://dashboard.gymnasiumsteglitz.de"
            end
        end
        response.headers["Access-Control-Request-Headers"] = "X-JWT"
        @latest_request_body = nil
        @latest_request_body_parsed = nil
        # before any API request, determine currently logged in user via the provided session ID
        @dashboard_jwt = nil
        @dashboard_user_email = nil
        @dashboard_user_display_name = nil
        @dashboard_teacher = nil
        if request.env["HTTP_X_JWT"]
            @dashboard_jwt = request.env["HTTP_X_JWT"]
            # STDERR.puts "Got a dashboard token!"
            # 1. decode token and check integrity via HS256
            decoded_token = JWT.decode(@dashboard_jwt, JWT_APPKEY_TRESOR, true, { :algorithm => "HS256" }).first
            # STDERR.puts decoded_token.to_yaml
            # 2. make sure the JWT is not expired
            diff = decoded_token["exp"] - Time.now.to_i
            assert(diff >= 0)
            @dashboard_user_email = decoded_token["email"]
            @dashboard_user_display_name = decoded_token["display_name"]
            @dashboard_teacher = decoded_token["teacher"]
        end

        if request.env["REQUEST_METHOD"] != "OPTIONS"
            if @dashboard_jwt
                debug "[#{(@dashboard_user_email || 'anon').split("@").first}@jwt] #{request.path}"
            end
        end
    end

    after "/jwt/*" do
        if @respond_content
            response.body = @respond_content
            response.headers["Content-Type"] = @respond_mimetype
            if @respond_filename
                response.headers["Content-Disposition"] = "attachment; filename=\"#{@respond_filename}\""
            end
        else
            @respond_hash ||= {}
            response.body = @respond_hash.to_json
        end
    end

    after "/public/*" do
        if @respond_content
            response.body = @respond_content
            response.headers["Content-Type"] = @respond_mimetype
            if @respond_filename
                response.headers["Content-Disposition"] = "attachment; filename=\"#{@respond_filename}\""
            end
        else
            @respond_hash ||= {}
            response.body = @respond_hash.to_json
        end
    end

    after '*' do
        cleanup_neo4j()
    end

    def respond(hash = {})
        @respond_hash = hash
    end

    def respond_raw_with_mimetype(content, mimetype)
        @respond_content = content
        @respond_mimetype = mimetype
    end

    def respond_raw_with_mimetype_and_filename(content, mimetype, filename)
        @respond_content = content
        @respond_mimetype = mimetype
        @respond_filename = filename
    end

    def htmlentities(s)
        @html_entities_coder ||= HTMLEntities.new
        @html_entities_coder.encode(s)
    end

    options "/jwt/*" do
        if DEVELOPMENT
            response.headers["Access-Control-Allow-Origin"] = "http://localhost:8025"
        else
            response.headers["Access-Control-Allow-Origin"] = "https://dashboard.gymnasiumsteglitz.de"
        end
        response.headers["Access-Control-Allow-Headers"] = "Content-Type, Access-Control-Allow-Origin,X-JWT"
        response.headers["Access-Control-Request-Headers"] = "X-JWT"
    end

    options "/public/*" do
        if DEVELOPMENT
            response.headers["Access-Control-Allow-Origin"] = "http://localhost:8025"
        else
            response.headers["Access-Control-Allow-Origin"] = "https://dashboard.gymnasiumsteglitz.de"
        end
        response.headers["Access-Control-Allow-Headers"] = "Content-Type, Access-Control-Allow-Origin"
    end

    def require_dashboard_jwt!
        assert(!@dashboard_jwt.nil?)
    end

    post "/jwt/ping" do
        require_dashboard_jwt!
        respond(:pong => "yay", :welcome => @dashboard_user_email)
    end

    get '/public/ping' do
        respond(:pong => "yay")
    end

    post '/public/ping' do
        respond(:pong => "yay")
    end

    post '/jwt/store' do
        # Schuljahr:2022_23/Halbjahr:1/Fach:Ma/Email:max.mustermann@mail.gymnasiumsteglitz.de Note 3+
        require_dashboard_jwt!
        data = parse_request_data(:required_keys => [:path, :key, :value])
        data[:value] = nil if data[:value].strip.empty?
        path = data[:path].strip
        tag = Digest::SHA1.hexdigest(path + '/' + data[:key] + SALT)[0, 16]
        email_hash = Digest::SHA1.hexdigest(@dashboard_user_email + SALT)[0, 16]
        neo4j_query(<<~END_OF_QUERY, :email => email_hash)
            MERGE (u:User {email: $email});
        END_OF_QUERY
        neo4j_query(<<~END_OF_QUERY, :email => email_hash, :tag => tag, :key => data[:key], :value => data[:value], :ts => Time.now.to_i)
            MATCH (u:User {email: $email})
            MERGE (e:Entry {tag: $tag})
            CREATE (u)-[r:UPDATED]->(e)
            SET r.ts = $ts
            SET r.value = $value
            SET e.value = $value
            SET e.ts_updated = $ts
        END_OF_QUERY
        @@cache[tag] = data[:value]
    end

    post '/jwt/get' do
        require_dashboard_jwt!
        data = parse_request_data(:required_keys => [:path, :key])
        path = data[:path].strip
        tag = Digest::SHA1.hexdigest(path + '/' + data[:key] + SALT)[0, 16]
        value = @@cache[tag]
        respond(:value => value)
    end

    def recurse_path_array(path_array, prefix = [], index_prefix = [], &block)
        if path_array.empty?
            yield prefix.join('/'), index_prefix
            return
        end
        path_entry = path_array[0]
        key = path_entry[0]
        values = path_entry[1]
        values = [values] unless values.is_a? Array
        values.each.with_index do |value, i|
            recurse_path_array(path_array[1, path_array.size - 1], prefix + ["#{key}:#{value}"], index_prefix + [i], &block)
        end
    end

    post '/jwt/get_many' do
        require_dashboard_jwt!
        data = parse_request_data(
            :required_keys => [:path_arrays, :key],
            :types => {:path_arrays => Array},
            :max_body_length => 1024 * 1024,
            :max_string_length => 1024 * 1024,
        )
        result_arrays = []
        data[:path_arrays].each do |array|
            result_array = []
            recurse_path_array(array) do |path, indices|
                p0 = result_array
                p = result_array
                indices.each do |i|
                    p0 = p
                    p[i] ||= []
                    p = p[i]
                end
                tag = Digest::SHA1.hexdigest(path + '/' + data[:key] + SALT)[0, 16]
                value = @@cache[tag]
                p0[indices.last] = value
            end
            result_arrays << result_array
        end
        respond(:results => result_arrays)
    end
end
