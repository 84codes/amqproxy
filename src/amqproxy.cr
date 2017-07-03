require "./amqproxy/version"
require "./amqproxy/server"
require "option_parser"
require "file"
require "ini"

url = "amqp://guest:guest@localhost:5672"
port = 1234
config = ""

OptionParser.parse! do |parser|
  parser.banner = "Usage: #{File.basename PROGRAM_NAME} [arguments]"
  parser.on("-c CONFIG_FILE", "--config=CONFIG_FILE", "Config file to read") do |c|
    config = c
  end
  parser.on("-u AMQP_URL", "--upstream=AMQP_URL", "URL to upstream server") do |u|
    url = u
  end
  parser.on("-p PORT", "--port=PORT", "Port to listen on") { |p| port = p.to_i }
  parser.on("-h", "--help", "Show this help") { puts parser; exit 1 }
  parser.invalid_option { |arg| abort "Invalid argument: #{arg}" }
end

unless config.empty?
  abort "Config file could not be read" unless File.file? config
  ini = INI.parse(File.read(config))
  p ini
end
server = AMQProxy::Server.new(url)
server.listen(port)
