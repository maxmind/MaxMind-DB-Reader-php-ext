# MaxMind DB Reader C Extension

This is the C extension for MaxMind DB Reader, providing significantly faster IP lookups compared to the pure PHP implementation.

## Installation (PIE - Recommended)

```bash
pie install maxmind-db/reader-ext
```

Precompiled binaries for common platforms are attached to each release, so on
those platforms no compiler or library headers are needed. Elsewhere PIE falls
back to building the extension from source.

## Prerequisites

When building from source, the extension requires the libmaxminddb C library:

### Ubuntu/Debian
```bash
sudo apt-get install libmaxminddb-dev
```

### macOS
```bash
brew install libmaxminddb
```

### Windows
See [libmaxminddb installation instructions](https://github.com/maxmind/libmaxminddb#installation).

## Documentation

See the main repository for full documentation: https://github.com/maxmind/MaxMind-DB-Reader-php

## Related Packages

- [maxmind-db/reader](https://packagist.org/packages/maxmind-db/reader) - Pure PHP implementation (no compilation needed)

## Support

Please report issues at: https://github.com/maxmind/MaxMind-DB-Reader-php/issues

## Copyright and License

This software is Copyright (c) 2014-2025 by MaxMind, Inc.

This is free software, licensed under the Apache License, Version 2.0.
