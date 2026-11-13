require "json"
STDIN.each_line { |l| puts ActionText::Content.new(JSON.parse(l)).to_html.to_json }
