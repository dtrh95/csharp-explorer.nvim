# Contributing to csharp-explorer.nvim

First off, thank you for considering contributing to `csharp-explorer.nvim`! It's people like you that make the open-source community such an amazing place to learn, inspire, and create.

## How Can I Contribute?

### Reporting Bugs

- **Check existing issues**: Someone might have already reported the same bug.
- **Provide context**: Include your Neovim version, OS, and a minimal configuration if possible.
- **Steps to reproduce**: Be as detailed as possible in how to trigger the issue.

### Suggesting Enhancements

- **Open an issue**: Describe why the feature would be useful and how it should work.
- **Draft a PR**: If you've already implemented it, feel free to open a Pull Request!

### Pull Requests

1. **Fork the repository**.
2. **Create a branch**: `git checkout -b feature/my-new-feature` or `git checkout -b bugfix/fix-some-issue`.
3. **Commit your changes**: Follow conventional commits if possible.
4. **Push to the branch**: `git push origin feature/my-new-feature`.
5. **Open a Pull Request**.

## Technical Details

The plugin is written in Lua and integrates closely with `nvim-tree.lua`. If you're adding new file system actions, please look at `lua/csharp-explorer/actions/fs.lua` to see how operations are proxied.

## Code of Conduct

Please be respectful and helpful to others in the community.
