#!/bin/bash
# Fuzz axum_dsl's image_variant (lib/axum_dsl/image_variant.rb) against Active Storage's variant processing
# (ImageProcessing::Vips: loader(page: 0).convert(format).resize_to_limit(w, h)), both on the parity reference image's
# libvips: gen.rb writes random PNG, JPEG (EXIF-rotated too), GIF and WebP inputs and Rails' variants, then app.axum.rb,
# built with axum_dsl and run inside the same image, makes its own; each pair is compared byte for byte. Usage: run.sh [seed] [count]
set -euo pipefail
cd "$(dirname "$0")"
HERE=$PWD DSL=${AXUM_DSL:-$HERE/../../../../axum_dsl} OUT=${OUT:-/tmp/fuzz_image_variant-out}
rm -rf run && mkdir -p run && chmod 777 run
rm -rf "$OUT" && (cd "$DSL" && ruby -Ilib exe/axum_dsl build "$HERE/app.axum.rb" -o "$OUT" --emit-only)
(cd "$OUT" && CARGO_TARGET_DIR=${CARGO_TARGET_DIR:-/tmp/axum_dsl_target} cargo build -q --locked)
cp "${CARGO_TARGET_DIR:-/tmp/axum_dsl_target}/debug/variantfuzz" run/
docker run --rm --user root --entrypoint sh -e SEED="${1:-1}" -e N="${2:-200}" -v "$HERE/run":/work -v "$HERE/gen.rb":/gen.rb \
  campfire-reference:app -c '
cd /rails && bundle exec ruby /gen.rb || exit 1
cd /work && PORT=4792 ./variantfuzz > app.log 2>&1 &
for i in $(seq 50); do curl -s -o /dev/null http://127.0.0.1:4792/v && break; sleep 0.1; done
same=0; diff=0; errs=0
while read src rails rust w h; do
  case "$rails" in ERROR*) errs=$((errs+1)); continue;; esac
  key=$(curl -s -G http://127.0.0.1:4792/v --data-urlencode "src=$src" --data-urlencode "name=$rust" -d w=$w -d h=$h)
  out=/work/store/$(echo $key | cut -c1-2)/$(echo $key | cut -c3-4)/$key
  if [ "$key" != ERROR ] && cmp -s "$rails" "$out"; then same=$((same+1)); else diff=$((diff+1)); echo "DIFF $src $w $h ($key)"; fi
done < /work/cases.txt
echo "same=$same diff=$diff rails_errors=$errs"'
