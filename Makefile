.PHONY: help check-strapi-venue-images check-strapi-venue-images-xlsx get-missing-venue-images get-missing-venue-images-dry-run download-reference-images-not-in-strapi download-reference-images-not-in-strapi-dry-run

help:
	@printf '%s\n' 'Available commands:'
	@printf '%s\n' '  make check-strapi-venue-images       Generate CSV report'
	@printf '%s\n' '  make check-strapi-venue-images-xlsx  Generate CSV + XLSX report with watermark sheet'
	@printf '%s\n' '  make get-missing-venue-images        Download NOK missing images into raw-image/'
	@printf '%s\n' '  make get-missing-venue-images-dry-run Preview missing image downloads'
	@printf '%s\n' '  make download-reference-images-not-in-strapi Download priority reference images absent from Strapi filename list'
	@printf '%s\n' '  make download-reference-images-not-in-strapi-dry-run Preview priority reference downloads'

check-strapi-venue-images:
	./script/check-strapi-venue-images.sh

check-strapi-venue-images-xlsx:
	OUTPUT_XLSX=1 ./script/check-strapi-venue-images.sh

get-missing-venue-images:
	./script/get-missing-images-from-report.sh

get-missing-venue-images-dry-run:
	DRY_RUN=1 ./script/get-missing-images-from-report.sh

download-reference-images-not-in-strapi:
	./script/download-reference-images-not-in-strapi.sh

download-reference-images-not-in-strapi-dry-run:
	DRY_RUN=1 ./script/download-reference-images-not-in-strapi.sh
