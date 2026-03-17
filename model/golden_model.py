#!/usr/bin/env python3
"""
KV-Cache Compression Engine — Golden Model
============================================
Bit-exact reference implementation for hardware verification.

Implements:
  1. Group quantization: FP16 → INT2/INT4 with per-group scales
  2. Outlier detection: values > Kσ stored at full precision
  3. Token eviction: attention-score-based pruning with sliding window
  4. Decompression: INT2/INT4 → FP16 with outlier restoration
  5. Test vector generation for RTL testbench
  6. HBM bandwidth analysis

THE METRICS:
  COMPRESSION_RATIO ≥ 8×
  RMSE < 0.01 (vs uncompressed FP16)

Usage:
  python model/golden_model.py
"""

import numpy as np
import struct
import os
import sys

# ============================================================
# Configuration
# ============================================================
class Config:
    # KV-cache dimensions (Llama-3 8B style)
    NUM_LAYERS    = 32
    NUM_KV_HEADS  = 8       # GQA: 8 KV heads (32 Q heads / 4 groups)
    HEAD_DIM      = 128
    SEQ_LEN       = 512     # tokens in cache
    
    # Quantization (asymmetric: Keys=INT4, Values=INT2 per KIVI paper)
    GROUP_SIZE    = 64      # elements per quantization group
    KEY_BITS      = 4       # INT4 for Keys (more sensitive)
    VALUE_BITS    = 2       # INT2 for Values (more tolerant)
    QUANT_BITS    = 2       # default for single-mode tests
    OUTLIER_K     = 4.0     # outlier threshold = K × σ
    
    # Token eviction
    EVICT_RATIO   = 0.5     # evict 50% of lowest-attention tokens
    WINDOW_SIZE   = 64      # always keep last W tokens (sliding window)
    
    # Test vector generation
    NUM_TEST_TILES = 4
    SEED          = 42

# ============================================================
# FP16 simulation helpers
# ============================================================
def to_fp16(x):
    """Simulate FP16 precision"""
    return np.float16(x).astype(np.float32)

def generate_kv_cache(cfg, layer=0, is_key=True):
    """
    Generate realistic KV-cache activations.
    Real KV caches have:
      - Most values near zero (normally distributed)
      - A few outlier channels with large magnitudes
      - Channel-wise patterns (some heads have larger variance)
    """
    rng = np.random.RandomState(cfg.SEED + layer * 100 + (0 if is_key else 50))
    
    # Base: normal distribution, σ ≈ 0.1
    kv = rng.randn(cfg.SEQ_LEN, cfg.HEAD_DIM).astype(np.float32) * 0.1
    
    # Inject outlier channels (2-3 channels per head have 10× magnitude)
    num_outlier_channels = max(2, cfg.HEAD_DIM // 64)
    outlier_channels = rng.choice(cfg.HEAD_DIM, num_outlier_channels, replace=False)
    for ch in outlier_channels:
        kv[:, ch] *= 10.0
    
    # Inject per-token outliers (rare, ~0.5% of values)
    outlier_mask = rng.random(kv.shape) < 0.005
    kv[outlier_mask] *= rng.uniform(5.0, 15.0, size=outlier_mask.sum())
    
    # Simulate FP16 precision
    kv = to_fp16(kv)
    
    return kv

def generate_attention_scores(cfg):
    """
    Generate realistic accumulated attention scores per token.
    Attention follows a power-law: a few tokens get most attention
    (attention sinks), recent tokens get high attention, middle is sparse.
    """
    rng = np.random.RandomState(cfg.SEED + 999)
    
    scores = np.zeros(cfg.SEQ_LEN, dtype=np.float32)
    
    # Attention sinks: first few tokens get disproportionate attention
    scores[:4] = rng.uniform(5.0, 10.0, size=4)
    
    # Recent tokens (sliding window): high attention
    window_start = max(4, cfg.SEQ_LEN - cfg.WINDOW_SIZE)
    scores[window_start:] = rng.uniform(2.0, 8.0, size=cfg.SEQ_LEN - window_start)
    
    # Middle tokens: power-law distribution (most are low)
    middle = scores[4:window_start]
    middle[:] = rng.pareto(1.5, size=len(middle)) * 0.3
    
    return scores

# ============================================================
# Group Quantization Engine
# ============================================================
class GroupQuantizer:
    """
    Per-group quantization with outlier protection.
    
    For each group of GROUP_SIZE elements:
      1. Compute group statistics (mean, σ)
      2. Detect outliers (|x| > K×σ)
      3. Compute scale from non-outlier elements
      4. Quantize non-outliers to QUANT_BITS
      5. Pack: quantized data + scale + outlier bitmap + outlier values
    """
    
    def __init__(self, cfg):
        self.cfg = cfg
        self.group_size = cfg.GROUP_SIZE
        self.quant_bits = cfg.QUANT_BITS
        self.outlier_k = cfg.OUTLIER_K
        
        # INT2: {-2, -1, 0, 1} → range [-2, 1]
        # INT4: {-8..7} → range [-8, 7]
        if self.quant_bits == 2:
            self.qmin, self.qmax = -2, 1
        elif self.quant_bits == 4:
            self.qmin, self.qmax = -8, 7
        else:
            self.qmin, self.qmax = -128, 127
    
    def compress_group(self, group):
        """
        Compress a single group of elements.
        
        Returns:
            quantized: array of int, shape [group_size]
            scale: float (FP16)
            outlier_bitmap: int (group_size bits)
            outlier_values: list of (index, FP16 value)
            stats: dict with compression statistics
        """
        assert len(group) == self.group_size
        
        # Step 1: Group statistics
        mu = np.mean(group)
        sigma = np.std(group)
        
        # Step 2: Outlier detection
        if sigma > 1e-8:
            threshold = self.outlier_k * sigma
        else:
            threshold = 1e6  # no outliers if σ ≈ 0
        
        outlier_bitmap = 0
        outlier_values = []
        normal_values = group.copy()
        
        for i in range(self.group_size):
            if abs(group[i]) > threshold:
                outlier_bitmap |= (1 << i)
                outlier_values.append((i, to_fp16(group[i])))
                normal_values[i] = 0.0  # zero out for scale computation
        
        # Step 3: Scale computation
        normal_abs_max = np.max(np.abs(normal_values))
        if normal_abs_max < 1e-8:
            scale = to_fp16(1.0)
        else:
            # Map qmax to normal_abs_max
            scale = to_fp16(normal_abs_max / abs(self.qmax))
        
        # Step 4: Quantize
        quantized = np.zeros(self.group_size, dtype=np.int8)
        if scale > 1e-8:
            inv_scale = 1.0 / scale
            for i in range(self.group_size):
                if (outlier_bitmap >> i) & 1:
                    quantized[i] = 0  # outlier slot: stored separately
                else:
                    q = int(np.round(group[i] * inv_scale))
                    quantized[i] = np.clip(q, self.qmin, self.qmax)
        
        # Step 5: Statistics
        num_outliers = bin(outlier_bitmap).count('1')
        
        # Compressed size (bits):
        #   group_size × quant_bits (quantized data)
        #   + 16 (scale, FP16)
        #   + group_size (outlier bitmap)
        #   + num_outliers × 16 (outlier values, FP16)
        compressed_bits = (self.group_size * self.quant_bits + 
                          16 + 
                          self.group_size + 
                          num_outliers * 16)
        original_bits = self.group_size * 16
        
        stats = {
            'num_outliers': num_outliers,
            'compressed_bits': compressed_bits,
            'original_bits': original_bits,
            'ratio': original_bits / max(1, compressed_bits),
            'scale': float(scale),
            'sigma': float(sigma),
        }
        
        return quantized, float(scale), outlier_bitmap, outlier_values, stats
    
    def decompress_group(self, quantized, scale, outlier_bitmap, outlier_values):
        """
        Decompress a single group.
        
        Returns:
            restored: array of float32, shape [group_size]
        """
        restored = np.zeros(self.group_size, dtype=np.float32)
        
        # Dequantize non-outlier values
        outlier_idx = 0
        for i in range(self.group_size):
            if (outlier_bitmap >> i) & 1:
                # Restore outlier at full precision
                _, val = outlier_values[outlier_idx]
                restored[i] = val
                outlier_idx += 1
            else:
                restored[i] = to_fp16(quantized[i] * scale)
        
        return restored
    
    def compress_tile(self, tile):
        """
        Compress an entire tile [seq_len, head_dim].
        
        Returns:
            compressed: list of group data
            metadata: overall compression statistics
        """
        flat = tile.flatten()
        num_groups = len(flat) // self.group_size
        assert len(flat) % self.group_size == 0, \
            f"Tile size {len(flat)} not divisible by group_size {self.group_size}"
        
        compressed_groups = []
        total_compressed_bits = 0
        total_original_bits = 0
        total_outliers = 0
        
        for g in range(num_groups):
            start = g * self.group_size
            group = flat[start:start + self.group_size]
            
            quantized, scale, bitmap, outliers, stats = self.compress_group(group)
            compressed_groups.append({
                'quantized': quantized,
                'scale': scale,
                'outlier_bitmap': bitmap,
                'outlier_values': outliers,
            })
            
            total_compressed_bits += stats['compressed_bits']
            total_original_bits += stats['original_bits']
            total_outliers += stats['num_outliers']
        
        metadata = {
            'num_groups': num_groups,
            'total_compressed_bits': total_compressed_bits,
            'total_original_bits': total_original_bits,
            'compression_ratio': total_original_bits / max(1, total_compressed_bits),
            'total_outliers': total_outliers,
            'avg_outliers_per_group': total_outliers / max(1, num_groups),
        }
        
        return compressed_groups, metadata
    
    def decompress_tile(self, compressed_groups, shape):
        """
        Decompress all groups back to a tile.
        """
        flat = np.zeros(shape[0] * shape[1], dtype=np.float32)
        
        for g, group_data in enumerate(compressed_groups):
            start = g * self.group_size
            restored = self.decompress_group(
                group_data['quantized'],
                group_data['scale'],
                group_data['outlier_bitmap'],
                group_data['outlier_values'],
            )
            flat[start:start + self.group_size] = restored
        
        return flat.reshape(shape)

# ============================================================
# Token Eviction Engine
# ============================================================
class TokenEvictor:
    """
    Attention-score-based token eviction with sliding window protection.
    """
    
    def __init__(self, cfg):
        self.cfg = cfg
        self.evict_ratio = cfg.EVICT_RATIO
        self.window_size = cfg.WINDOW_SIZE
    
    def compute_eviction_mask(self, attn_scores):
        """
        Compute which tokens to keep.
        
        Returns:
            keep_mask: boolean array [seq_len]
            stats: eviction statistics
        """
        seq_len = len(attn_scores)
        keep_mask = np.ones(seq_len, dtype=bool)
        
        # Always protect sliding window (recent tokens)
        window_start = max(0, seq_len - self.window_size)
        
        # Always protect attention sinks (first 4 tokens)
        sink_end = min(4, seq_len)
        
        # Evictable region: between sinks and window
        evictable = np.zeros(seq_len, dtype=bool)
        evictable[sink_end:window_start] = True
        
        if evictable.sum() > 0:
            # Sort evictable tokens by attention score
            evictable_indices = np.where(evictable)[0]
            evictable_scores = attn_scores[evictable_indices]
            
            # Evict bottom evict_ratio of evictable tokens
            num_to_evict = int(len(evictable_indices) * self.evict_ratio)
            if num_to_evict > 0:
                sorted_indices = evictable_indices[np.argsort(evictable_scores)]
                evict_indices = sorted_indices[:num_to_evict]
                keep_mask[evict_indices] = False
        
        stats = {
            'total_tokens': seq_len,
            'kept_tokens': keep_mask.sum(),
            'evicted_tokens': (~keep_mask).sum(),
            'eviction_ratio': (~keep_mask).sum() / max(1, seq_len),
            'protected_sinks': sink_end,
            'protected_window': seq_len - window_start,
        }
        
        return keep_mask, stats

# ============================================================
# End-to-End Compression Pipeline
# ============================================================
def compress_kv_cache(cfg, kv_tile, attn_scores=None):
    """
    Full compression pipeline: eviction + quantization.
    
    Returns:
        compressed: compressed data
        metadata: compression statistics
        keep_mask: which tokens were kept
    """
    quantizer = GroupQuantizer(cfg)
    
    # Step 1: Token eviction (if attention scores provided)
    if attn_scores is not None:
        evictor = TokenEvictor(cfg)
        keep_mask, evict_stats = evictor.compute_eviction_mask(attn_scores)
        kv_kept = kv_tile[keep_mask]
    else:
        keep_mask = np.ones(kv_tile.shape[0], dtype=bool)
        evict_stats = {'evicted_tokens': 0, 'kept_tokens': kv_tile.shape[0]}
        kv_kept = kv_tile
    
    # Pad to group_size boundary if needed
    num_elements = kv_kept.shape[0] * kv_kept.shape[1]
    pad_needed = (cfg.GROUP_SIZE - (num_elements % cfg.GROUP_SIZE)) % cfg.GROUP_SIZE
    if pad_needed > 0:
        kv_padded = np.zeros((kv_kept.shape[0], kv_kept.shape[1] + pad_needed // kv_kept.shape[0] + 1), 
                            dtype=np.float32)
        kv_padded[:kv_kept.shape[0], :kv_kept.shape[1]] = kv_kept
        # Recalculate with proper padding
        flat = kv_kept.flatten()
        pad_len = (cfg.GROUP_SIZE - (len(flat) % cfg.GROUP_SIZE)) % cfg.GROUP_SIZE
        flat_padded = np.concatenate([flat, np.zeros(pad_len)])
        kv_for_compress = flat_padded.reshape(-1, kv_kept.shape[1]) if pad_len == 0 else None
    
    # Simple approach: ensure tile is group-aligned
    if kv_kept.size % cfg.GROUP_SIZE != 0:
        flat = kv_kept.flatten()
        pad_len = (cfg.GROUP_SIZE - (len(flat) % cfg.GROUP_SIZE)) % cfg.GROUP_SIZE
        flat = np.concatenate([flat, np.zeros(pad_len, dtype=np.float32)])
        # Reshape to fake tile for compression
        new_dim = cfg.HEAD_DIM
        new_seq = len(flat) // new_dim
        kv_for_quant = flat.reshape(new_seq, new_dim)
    else:
        kv_for_quant = kv_kept
    
    # Step 2: Group quantization
    compressed_groups, quant_stats = quantizer.compress_tile(kv_for_quant)
    
    # Combined statistics
    # Effective compression includes both quantization and eviction
    original_size_bits = kv_tile.shape[0] * kv_tile.shape[1] * 16
    compressed_size_bits = quant_stats['total_compressed_bits']
    effective_ratio = original_size_bits / max(1, compressed_size_bits)
    
    metadata = {
        'quantization': quant_stats,
        'eviction': evict_stats,
        'original_size_bits': original_size_bits,
        'compressed_size_bits': compressed_size_bits,
        'quant_only_ratio': quant_stats['compression_ratio'],
        'effective_ratio': effective_ratio,
    }
    
    return compressed_groups, metadata, keep_mask

def decompress_kv_cache(cfg, compressed_groups, keep_mask, original_shape):
    """
    Full decompression pipeline.
    """
    quantizer = GroupQuantizer(cfg)
    
    # Decompress quantized data
    kept_seq = keep_mask.sum()
    decompress_shape = (kept_seq, original_shape[1])
    
    # Handle padding
    total_elements = kept_seq * original_shape[1]
    pad_len = (cfg.GROUP_SIZE - (total_elements % cfg.GROUP_SIZE)) % cfg.GROUP_SIZE
    padded_elements = total_elements + pad_len
    
    flat_restored = np.zeros(padded_elements, dtype=np.float32)
    for g, group_data in enumerate(compressed_groups):
        start = g * cfg.GROUP_SIZE
        restored = quantizer.decompress_group(
            group_data['quantized'],
            group_data['scale'],
            group_data['outlier_bitmap'],
            group_data['outlier_values'],
        )
        flat_restored[start:start + cfg.GROUP_SIZE] = restored
    
    # Trim padding and reshape
    flat_restored = flat_restored[:total_elements]
    kv_restored_kept = flat_restored.reshape(kept_seq, original_shape[1])
    
    # Reconstruct full sequence (zero-fill evicted positions)
    kv_restored = np.zeros(original_shape, dtype=np.float32)
    kept_indices = np.where(keep_mask)[0]
    kv_restored[kept_indices] = kv_restored_kept
    
    return kv_restored

# ============================================================
# Test Vector Generation
# ============================================================
def generate_test_vectors(cfg, output_dir='test_vectors'):
    """
    Generate binary test vectors for RTL testbench.
    
    File format (all little-endian):
      *_input.bin:  FP16 values, packed as uint16
      *_compressed.bin: compressed bitstream
      *_output.bin: restored FP16 values
      *_meta.bin:  scales, bitmaps, outlier counts
    """
    os.makedirs(output_dir, exist_ok=True)
    
    print(f"\n  Generating test vectors in {output_dir}/")
    
    for t in range(cfg.NUM_TEST_TILES):
        # Generate test tile (smaller than full cache for RTL sim)
        test_seq = 64   # 64 tokens per test tile
        test_dim = cfg.HEAD_DIM
        
        rng = np.random.RandomState(cfg.SEED + t * 1000)
        
        if t == 0:
            # Test 0: Normal distribution, no outliers
            tile = rng.randn(test_seq, test_dim).astype(np.float32) * 0.1
            desc = "normal, no outliers"
        elif t == 1:
            # Test 1: With outlier channels
            tile = rng.randn(test_seq, test_dim).astype(np.float32) * 0.1
            tile[:, 0] *= 20.0   # outlier channel 0
            tile[:, 63] *= 15.0  # outlier channel 63
            desc = "with outlier channels"
        elif t == 2:
            # Test 2: Sparse (many zeros)
            tile = rng.randn(test_seq, test_dim).astype(np.float32) * 0.1
            tile[tile.abs() < 0.05 if hasattr(tile, 'abs') else np.abs(tile) < 0.05] = 0.0
            desc = "sparse (many zeros)"
        else:
            # Test 3: Uniform distribution
            tile = rng.uniform(-1.0, 1.0, (test_seq, test_dim)).astype(np.float32)
            desc = "uniform distribution"
        
        tile = to_fp16(tile)
        
        # Compress
        quantizer = GroupQuantizer(cfg)
        compressed_groups, meta = quantizer.compress_tile(tile)
        
        # Decompress
        restored = quantizer.decompress_group  # will use full tile method
        flat_restored = np.zeros(tile.size, dtype=np.float32)
        for g, group_data in enumerate(compressed_groups):
            start = g * cfg.GROUP_SIZE
            r = quantizer.decompress_group(
                group_data['quantized'],
                group_data['scale'],
                group_data['outlier_bitmap'],
                group_data['outlier_values'],
            )
            flat_restored[start:start + cfg.GROUP_SIZE] = r
        restored = flat_restored.reshape(tile.shape)
        
        # Error metrics
        rmse = np.sqrt(np.mean((tile - restored) ** 2))
        max_err = np.max(np.abs(tile - restored))
        
        # Write binary files
        # Input: FP16 as uint16
        input_fp16 = np.float16(tile.flatten())
        input_fp16.tofile(os.path.join(output_dir, f'tile{t}_input.bin'))
        
        # Compressed: pack groups sequentially
        # Format per group: [scale:u16] [bitmap:u64] [num_outliers:u8] [outlier_vals:u16×N] [quant_data: group_size×bits]
        with open(os.path.join(output_dir, f'tile{t}_compressed.bin'), 'wb') as f:
            for group_data in compressed_groups:
                # Scale as FP16 (uint16)
                scale_fp16 = np.float16(group_data['scale'])
                f.write(np.array([scale_fp16], dtype=np.float16).tobytes())
                
                # Outlier bitmap (64 bits = 8 bytes)
                f.write(struct.pack('<Q', group_data['outlier_bitmap']))
                
                # Number of outliers (1 byte)
                num_outliers = len(group_data['outlier_values'])
                f.write(struct.pack('<B', num_outliers))
                
                # Outlier values (FP16 each)
                for idx, val in group_data['outlier_values']:
                    f.write(struct.pack('<B', idx))  # index within group
                    f.write(np.array([val], dtype=np.float16).tobytes())
                
                # Quantized data (pack INT2 into bytes: 4 values per byte)
                qdata = group_data['quantized']
                if cfg.QUANT_BITS == 2:
                    # Pack 4 INT2 values per byte
                    for i in range(0, cfg.GROUP_SIZE, 4):
                        byte_val = 0
                        for j in range(4):
                            if i + j < cfg.GROUP_SIZE:
                                # INT2: map {-2,-1,0,1} to {0,1,2,3}
                                val = int(qdata[i + j]) + 2
                                byte_val |= (val & 0x3) << (j * 2)
                        f.write(struct.pack('<B', byte_val))
                else:
                    # INT4 or INT8: direct
                    f.write(qdata.tobytes())
        
        # Output: restored FP16
        output_fp16 = np.float16(restored.flatten())
        output_fp16.tofile(os.path.join(output_dir, f'tile{t}_output.bin'))
        
        print(f"    Tile {t} ({desc}): ratio={meta['compression_ratio']:.2f}×, "
              f"RMSE={rmse:.6f}, max_err={max_err:.6f}, "
              f"outliers={meta['total_outliers']}")
    
    print(f"  Test vectors written to {output_dir}/")

# ============================================================
# Main: Full Analysis
# ============================================================
def main():
    cfg = Config()
    np.random.seed(cfg.SEED)
    
    print("=" * 60)
    print("  KV-Cache Compression Engine — Golden Model")
    print("  Target: COMPRESSION_RATIO ≥ 8×, RMSE < 0.01")
    print("=" * 60)
    
    # ---- Phase 1: Asymmetric quantization analysis (KIVI-style) ----
    print("\n[Phase 1] Asymmetric Quantization Analysis (K=INT4, V=INT2)")
    print(f"  Config: GROUP_SIZE={cfg.GROUP_SIZE}, KEY_BITS={cfg.KEY_BITS}, "
          f"VALUE_BITS={cfg.VALUE_BITS}, OUTLIER_K={cfg.OUTLIER_K}")
    
    all_ratios = []
    all_rmses = []
    all_outlier_counts = []
    
    for layer in range(min(4, cfg.NUM_LAYERS)):  # Analyze first 4 layers
        for is_key in [True, False]:
            kv = generate_kv_cache(cfg, layer=layer, is_key=is_key)
            name = f"L{layer}_{'K' if is_key else 'V'}"
            
            # Use appropriate bit width
            bits = cfg.KEY_BITS if is_key else cfg.VALUE_BITS
            cfg_mode = Config()
            cfg_mode.QUANT_BITS = bits
            quantizer = GroupQuantizer(cfg_mode)
            
            compressed_groups, meta = quantizer.compress_tile(kv)
            
            # Decompress
            flat_restored = np.zeros(kv.size, dtype=np.float32)
            for g, gd in enumerate(compressed_groups):
                start = g * cfg.GROUP_SIZE
                r = quantizer.decompress_group(
                    gd['quantized'], gd['scale'],
                    gd['outlier_bitmap'], gd['outlier_values'])
                flat_restored[start:start + cfg.GROUP_SIZE] = r
            restored = flat_restored.reshape(kv.shape)
            
            rmse = np.sqrt(np.mean((kv - restored) ** 2))
            max_err = np.max(np.abs(kv - restored))
            
            all_ratios.append(meta['compression_ratio'])
            all_rmses.append(rmse)
            all_outlier_counts.append(meta['avg_outliers_per_group'])
            
            print(f"  {name}: ratio={meta['compression_ratio']:.2f}×, "
                  f"RMSE={rmse:.6f}, max_err={max_err:.6f}, "
                  f"outliers/group={meta['avg_outliers_per_group']:.2f}")
    
    avg_quant_ratio = np.mean(all_ratios)
    avg_rmse = np.mean(all_rmses)
    max_rmse = np.max(all_rmses)
    
    print(f"\n  Quantization-only summary:")
    print(f"    Avg compression ratio: {avg_quant_ratio:.2f}×")
    print(f"    Avg RMSE:              {avg_rmse:.6f}")
    print(f"    Max RMSE:              {max_rmse:.6f}")
    print(f"    Avg outliers/group:    {np.mean(all_outlier_counts):.2f}")
    
    # ---- Phase 2: Token eviction analysis ----
    print("\n[Phase 2] Token Eviction Analysis")
    
    attn_scores = generate_attention_scores(cfg)
    evictor = TokenEvictor(cfg)
    keep_mask, evict_stats = evictor.compute_eviction_mask(attn_scores)
    
    print(f"  Total tokens:     {evict_stats['total_tokens']}")
    print(f"  Kept tokens:      {evict_stats['kept_tokens']}")
    print(f"  Evicted tokens:   {evict_stats['evicted_tokens']}")
    print(f"  Eviction ratio:   {evict_stats['eviction_ratio']:.2%}")
    print(f"  Protected sinks:  {evict_stats['protected_sinks']}")
    print(f"  Protected window: {evict_stats['protected_window']}")
    
    # ---- Phase 3: Combined pipeline ----
    print("\n[Phase 3] Combined Pipeline (Eviction + Quantization)")
    
    kv = generate_kv_cache(cfg, layer=0, is_key=True)
    
    compressed, meta, mask = compress_kv_cache(cfg, kv, attn_scores)
    restored = decompress_kv_cache(cfg, compressed, mask, kv.shape)
    
    # RMSE on kept tokens only (evicted tokens are zero, which is expected)
    kept_indices = np.where(mask)[0]
    rmse_kept = np.sqrt(np.mean((kv[kept_indices] - restored[kept_indices]) ** 2))
    rmse_all = np.sqrt(np.mean((kv - restored) ** 2))
    
    print(f"  Quantization-only ratio: {meta['quant_only_ratio']:.2f}×")
    print(f"  Effective ratio (with eviction): {meta['effective_ratio']:.2f}×")
    print(f"  RMSE (kept tokens only): {rmse_kept:.6f}")
    print(f"  RMSE (all, evicted=0):   {rmse_all:.6f}")
    
    # ---- Phase 4: HBM bandwidth analysis ----
    print("\n[Phase 4] HBM Bandwidth Analysis")
    
    configs = [
        ("Llama-3 8B",   32, 8,  128, 512),
        ("Llama-3 8B",   32, 8,  128, 2048),
        ("Llama-3 8B",   32, 8,  128, 8192),
        ("Llama-3 70B",  80, 8,  128, 2048),
        ("Llama-3 70B",  80, 8,  128, 32768),
        ("Llama-3 70B",  80, 8,  128, 131072),
    ]
    
    print(f"  {'Model':<16} {'Layers':>6} {'Heads':>5} {'Dim':>4} "
          f"{'SeqLen':>7} {'FP16':>8} {'Compressed':>10} {'Ratio':>6}")
    print(f"  {'-'*16} {'-'*6} {'-'*5} {'-'*4} {'-'*7} {'-'*8} {'-'*10} {'-'*6}")
    
    for model_name, n_layers, n_heads, head_dim, seq_len in configs:
        fp16_bytes = 2 * n_layers * n_heads * seq_len * head_dim * 2  # 2 for K+V
        
        # Estimate compressed size using measured ratios
        effective_ratio = meta['effective_ratio']
        compressed_bytes = fp16_bytes / effective_ratio
        
        fp16_gb = fp16_bytes / (1024**3)
        comp_gb = compressed_bytes / (1024**3)
        
        print(f"  {model_name:<16} {n_layers:>6} {n_heads:>5} {head_dim:>4} "
              f"{seq_len:>7} {fp16_gb:>7.2f}G {comp_gb:>9.2f}G {effective_ratio:>5.1f}×")
    
    # ---- Phase 5: Test vector generation ----
    print("\n[Phase 5] Test Vector Generation")
    generate_test_vectors(cfg, output_dir='test_vectors')
    
    # ---- Final verdict ----
    print("\n" + "=" * 60)
    print("  RESULTS")
    print("=" * 60)
    
    quant_pass = avg_rmse < 0.01
    ratio_pass = meta['effective_ratio'] >= 8.0
    
    print(f"  RMSE (quant-only avg): {avg_rmse:.6f}  "
          f"{'[PASS]' if quant_pass else '[WARN]'} (target < 0.01)")
    print(f"  Effective ratio:       {meta['effective_ratio']:.2f}×   "
          f"{'[PASS]' if ratio_pass else '[WARN]'} (target ≥ 8×)")
    
    if quant_pass and ratio_pass:
        print(f"\n  >>> GOLDEN MODEL VERIFIED <<<")
    else:
        if not quant_pass:
            print(f"\n  [WARN] RMSE {avg_rmse:.6f} exceeds 0.01 target")
            print(f"         Consider: larger GROUP_SIZE, INT4 mode, or lower OUTLIER_K")
        if not ratio_pass:
            print(f"\n  [WARN] Ratio {meta['effective_ratio']:.2f}× below 8× target")
            print(f"         Consider: higher EVICT_RATIO or INT2 quantization")
    
    print("")
    return 0

if __name__ == '__main__':
    sys.exit(main())
