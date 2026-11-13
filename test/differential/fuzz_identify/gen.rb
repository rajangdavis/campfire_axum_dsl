# Random uploads (bytes, filename, declared Content-Type) and what Active Storage records for them:
# Blob#identify_content_type (Marcel over the first 4 KB, the filename and the declared type) and, for an image/* type,
# ImageAnalyzer::Vips's width and height (swapped for Rails' ROTATIONS). Writes /work/cases/<n> and /work/expected.txt.
require "vips"
require "marcel"
require "json"
srand(Integer(ENV.fetch("SEED", "1")))
N = Integer(ENV.fetch("N", "300"))
dir = "/work/cases"; Dir.mkdir(dir) unless Dir.exist?(dir)
def img(w, h, bands)
  base = Vips::Image.gaussnoise(w, h).cast(:uchar)
  bands == 1 ? base : base.bandjoin(Array.new(bands - 1) { Vips::Image.gaussnoise(w, h).cast(:uchar) })
end
kinds = %w[jpg jpg_rot png png_exif webp webp_exif gif tiff tiff_rot pdf svg svg_viewbox svg_units text random bmp ico empty_png csv zip html docx xlsx ole mp3 mp4 wav]
exts = %w[jpg jpeg png gif webp tiff pdf svg txt bin heic ico bmp JPG Png csv md json zip mp4 mov docx tar.gz xlsx doc xls html htm mp3 wav] + ["", "."]
declared = ["text/csv", "application/zip", "text/plain; charset=utf-8", "image/jpeg", "image/png", "application/octet-stream", nil, "text/plain", "image/gif; charset=binary",
            "IMAGE/PNG", "application/pdf", "image/webp", "bogus", "video/mp4"]
lines = []
N.times do |i|
  kind = kinds.sample; w = rand(1..900); h = rand(1..900)
  path = "#{dir}/#{i}"
  case kind
  when "jpg" then img(w, h, 3).write_to_file("#{path}.jpg"); File.rename("#{path}.jpg", path)
  when "jpg_rot", "png_exif", "webp_exif"
    ext = { "jpg_rot" => "jpg", "png_exif" => "png", "webp_exif" => "webp" }[kind]
    x = img(w, h, 3).copy; x.set_type(GObject::GINT_TYPE, "orientation", rand(1..8)); x.write_to_file("#{path}.#{ext}"); File.rename("#{path}.#{ext}", path)
  when "png" then img(w, h, [1, 2, 3, 4].sample).write_to_file("#{path}.png"); File.rename("#{path}.png", path)
  when "webp" then img(w, h, [3, 4].sample).write_to_file("#{path}.webp"); File.rename("#{path}.webp", path)
  when "gif" then img(w, h, 3).write_to_file("#{path}.gif"); File.rename("#{path}.gif", path)
  when "tiff" then img(w, h, 3).write_to_file("#{path}.tif"); File.rename("#{path}.tif", path)
  when "tiff_rot" then x = img(w, h, 3).copy; x.set_type(GObject::GINT_TYPE, "orientation", rand(1..8)); x.write_to_file("#{path}.tif"); File.rename("#{path}.tif", path)
  when "svg_viewbox" then File.write(path, "<svg xmlns=\"http://www.w3.org/2000/svg\" viewBox=\"0 0 #{w} #{h}\"><rect width=\"5\" height=\"5\"/></svg>")
  when "svg_units" then File.write(path, "<svg xmlns=\"http://www.w3.org/2000/svg\" width=\"#{w}.4px\" height=\"#{h}\"><rect width=\"5\" height=\"5\"/></svg>")
  when "html" then File.write(path, "#{" " * rand(0..30)}<!DOCTYPE html><html><body>x</body></html>")
  when "docx", "xlsx" then File.binwrite(path, "PK\x03\x04".b + "\x00".b * 26 + "[Content_Types].xml".b + "\x00".b * rand(0..200) + (kind == "docx" ? "word/" : "xl/").b + Random.bytes(50))
  when "ole" then File.binwrite(path, "\xD0\xCF\x11\xE0\xA1\xB1\x1A\xE1".b + Random.bytes(600))
  when "mp3" then File.binwrite(path, "ID3".b + Random.bytes(200))
  when "mp4" then File.binwrite(path, "\x00\x00\x00\x18ftypmp42".b + Random.bytes(200))
  when "wav" then File.binwrite(path, "RIFF".b + Random.bytes(4) + "WAVEfmt ".b + Random.bytes(100))
  when "csv" then File.write(path, "a,b\n1,2\n" * rand(1..20))
  when "zip" then File.binwrite(path, "PK\x03\x04".b + Random.bytes(100))
  when "pdf" then File.binwrite(path, "%PDF-1.4\n%\xE2\xE3\xCF\xD3\n1 0 obj << >> endobj\ntrailer << >>\n%%EOF\n".b)
  when "svg" then File.write(path, "<?xml version=\"1.0\"?>\n<svg xmlns=\"http://www.w3.org/2000/svg\" width=\"#{w}\" height=\"#{h}\"><rect width=\"5\" height=\"5\"/></svg>\n")
  when "text" then File.write(path, "hello #{i}\n" * rand(1..50))
  when "random" then File.binwrite(path, Random.bytes(rand(0..5000)))
  when "bmp" then File.binwrite(path, "BM".b + "\x00".b * 24 + "\x01\x00\x18\x00".b + Random.bytes(40))
  when "ico" then File.binwrite(path, "\x00\x00\x01\x00".b + Random.bytes(60))
  when "empty_png" then File.binwrite(path, "\x89PNG\r\n\x1a\n".b)
  end
  name = ["file#{i}", ".hidden#{i}", "my.file#{i}"].sample + ((e = exts.sample).empty? ? "" : ".#{e}")
  dt = declared.sample
  data = File.binread(path)
  type = Marcel::MimeType.for(StringIO.new(data[0, 4096] || ""), name: name, declared_type: dt)
  meta = { identified: true }
  if type.start_with?("image/")
    begin
      v = Vips::Image.new_from_file(path, access: :sequential)
      rot = (v.get("exif-ifd0-Orientation") rescue nil)
      meta.merge!(/Right-top|Left-bottom|Top-right|Bottom-left/ === rot ? { width: v.height, height: v.width } : { width: v.width, height: v.height })
    rescue Vips::Error
    end
  end
  meta[:analyzed] = true
  lines << [i, name, dt.to_s.gsub(" ", "%20"), type, meta.to_json].join(" ")
end
File.write("/work/expected.txt", lines.join("\n") + "\n")
puts "#{N} cases"
