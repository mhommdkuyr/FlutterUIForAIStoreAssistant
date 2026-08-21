# Yemen 3000-SKU training status

The pipeline is resumable in six 500-SKU batches. Each batch requires 500 hydrated product images and 500 MobileCLIP2-S0 512D centroids before it can publish an artifact. The final assembly requires all six batches and exactly 3000 unique SKUs before the release APK is built.

Image hydration uses the Open Food Facts AWS S3 image dataset rather than the public image server, which is the recommended path for large-scale image downloads.
