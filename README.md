# dirls
An HTML directory listing script written for a Linux college class

# Features
- custom file categories
- custom CSS styles
- builtin HTTP server

# Usage
```
./dirls.sh --help
```

# Configuration
Location: `$XDG_CONFIG_HOME/dirls/`, i.e. `~/.config/dirls/`
Default config will be autogenerated if not present.

# Dependencies
bash, find, grep with PCRE support, sed, nc, wc, realpath, stat
