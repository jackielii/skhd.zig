# SOA (Struct of Arrays) Optimization

## Overview

We implemented and benchmarked three versions of the Hotkey process mapping system to address the performance gap mentioned in TODO.md (1.6% CPU vs 0.6% for original skhd).

## Performance Results

```
Process Mapping (Original):       170ns per lookup
Process Mapping (Manual SOA):     42ns per lookup (4x speedup)
Process Mapping (MultiArrayList): 28ns per lookup (6x speedup)
```

## Implementation Comparison

### 1. Original (Hotkey.zig)
- Parallel arrays for process names and commands
- Linear search with lowercase conversion on every lookup
- Good structure but inefficient lookup

### 2. Manual SOA (HotkeySOA.zig)
- Added pre-computed hash array
- Hash comparison before string comparison
- Lowercase conversion done once at insertion
- 4x performance improvement

### 3. MultiArrayList (HotkeyMultiArray.zig)
- Uses `std.MultiArrayList` for automatic SOA layout
- Best cache locality through standard library optimizations
- Cleanest implementation with 6x performance improvement

## Key Optimizations

1. **Pre-computed Hashes**: Calculate hash once during insertion, not on every lookup
2. **Cache-Friendly Layout**: Related data (hashes) stored contiguously
3. **Reduced String Operations**: Lowercase conversion happens once
4. **Efficient Access Pattern**: Check hashes first, access strings only on match

## Memory Layout Benefits

```zig
// Traditional AOS: Poor cache usage
[{name, hash, cmd}, {name, hash, cmd}, ...]

// SOA with MultiArrayList: Optimal cache usage
[hash, hash, hash, ...] // Hot data together
[name, name, name, ...] // Cold data together
[cmd,  cmd,  cmd,  ...] // Rarely accessed
```

## Recommendation

Use `std.MultiArrayList` (HotkeyMultiArray.zig) because:
- **Best Performance**: 6x speedup over original
- **Idiomatic Zig**: Standard library pattern
- **Maintainable**: Less manual memory management
- **Future-proof**: Benefits from stdlib improvements

## Integration Steps

1. Replace Hotkey.zig with HotkeyMultiArray.zig
2. Update Parser to use `add_process_mapping()` API
3. Run full application benchmarks to verify improvement