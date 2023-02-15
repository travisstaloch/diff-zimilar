# diff-zimilar

a port of [dtolnay/dissimilar](https://github.com/dtolnay/dissimilar/) text diffing library to [zig](https://ziglang.org/). includes semantic cleanups.  based on google's diff match patch. 

# goals

* reduced memory footprint, limited allocations
* fast diffing, maybe for use in [zls](https://github.com/zigtools/zls)

# references

* inspired by [tomhoule/zig-diff](https://github.com/tomhoule/zig-diff/)
* ported from [dtolnay/dissimilar](https://github.com/dtolnay/dissimilar/)
* [google diff match patch](https://github.com/google/diff-match-patch)
* [Myers' diff algorithm](https://neil.fraser.name/writing/diff/myers.pdf)
* [semantic cleanups](https://neil.fraser.name/writing/diff/)
