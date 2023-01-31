# -------------------------------------------------------------------
# Diese Datei bitte unter credentials.rb speichern und Werte anpassen
# (bitte keine Credentials in Git committen)
# -------------------------------------------------------------------

DEVELOPMENT = ENV['DEVELOPMENT']

WEBSITE_HOST = 'some_host_at_gyst'
WEB_ROOT = DEVELOPMENT ? 'http://localhost:8025' : "https://#{WEBSITE_HOST}"

JWT_APPKEY_TRESOR = 'something'
SALT = 'something else'