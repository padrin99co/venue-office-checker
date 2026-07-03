.PHONY: help check-strapi-venue-images check-strapi-venue-images-xlsx

help:
	@printf '%s\n' 'Available commands:'
	@printf '%s\n' '  make check-strapi-venue-images       Generate CSV report'
	@printf '%s\n' '  make check-strapi-venue-images-xlsx  Generate CSV + XLSX report with watermark sheet'

check-strapi-venue-images:
	./script/check-strapi-venue-images.sh

check-strapi-venue-images-xlsx:
	OUTPUT_XLSX=1 ./script/check-strapi-venue-images.sh
