# Yemen 3000 SKU Training

The visual catalog is trained in six independent 500-SKU MobileCLIP2 enrollment batches. Every batch must produce exactly 500 image-backed products, 500 recognition-ready records, and a 500x512 centroid matrix. The release job assembles all six verified batches and refuses to build an APK unless the combined result is exactly 3000 products and 3000 vectors.
