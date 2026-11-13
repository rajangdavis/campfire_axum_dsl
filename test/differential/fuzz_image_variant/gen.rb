# Random images through Active Storage's exact call (ImageProcessingTransformer#process):
#   ImageProcessing::Vips.source(file).loader(page: 0).convert(format).resize_to_limit(w, h).call
# then axum_dsl's image_variant (app.axum.rb) on the same inputs; the outputs are compared byte for byte (run.sh).
require "image_processing/vips"
require "digest"
srand(Integer(ENV.fetch("SEED", "1")))
n = Integer(ENV.fetch("N", "200"))
dir = "/work/cases"; Dir.mkdir(dir) unless Dir.exist?(dir)
limits = [[1200, 800], [512, 512], [192, 192]]
inputs = %w[png jpg gif webp]
outputs = %w[png webp jpg gif]
cases = []
n.times do |i|
  w = [rand(1..3000), rand(1..40)].sample; h = [rand(1..3000), rand(1..40)].sample
  w = rand(1..2600) if rand < 0.7; h = rand(1..2600) if rand < 0.7
  bands = [1, 2, 3, 4].sample
  img = Vips::Image.gaussnoise(w, h, mean: rand(40..200), sigma: rand(5..80))
  img = img.bandjoin([img.rot180.resize(1.0).crop(0, 0, w, h)] * (bands - 1)) if bands > 1 rescue img
  img = (img + Vips::Image.xyz(w, h)[0] * rand(0.0..0.3)).cast(:uchar)
  img = img.bandjoin(Array.new(bands - img.bands) { img[0] }) if img.bands < bands
  in_ext = inputs.sample
  in_ext = "png" if [2, 4].include?(bands) && in_ext == "jpg"
  src = "#{dir}/in#{i}.#{in_ext}"
  if in_ext == "jpg" && rand < 0.5
    img = img.copy; img.set_type(GObject::GINT_TYPE, "orientation", rand(1..8)); img.write_to_file(src, Q: rand(50..95))
  else
    img.write_to_file(src)
  end
  mw, mh = limits.sample
  out_ext = rand < 0.6 ? (in_ext == "jpg" ? "jpg" : in_ext) : outputs.sample
  dst = "#{dir}/rails#{i}.#{out_ext}"
  begin
    ImageProcessing::Vips.source(src).loader(page: 0).convert(out_ext).resize_to_limit(mw, mh).call(destination: dst)
  rescue => e
    dst = "ERROR #{e.class}"
  end
  cases << [src, dst, "rust#{i}.#{out_ext}", mw, mh]
end
File.write("/work/cases.txt", cases.map { |c| c.join(" ") }.join("\n") + "\n")
puts "#{cases.size} cases, vips #{Vips.version_string}"
