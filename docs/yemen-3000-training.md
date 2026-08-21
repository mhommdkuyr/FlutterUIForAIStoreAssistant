# Yemen 3000 SKU Training

The release candidate downloads one 150000-record Open Food Facts JSONL source artifact and fans it into six independent 500-SKU MobileCLIP2 training batches. Each batch is validated before assembly; the release refuses to build unless the combined catalog contains exactly 3000 unique recognition-ready products and 3000 vectors of 512 dimensions.
