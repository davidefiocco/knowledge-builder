FROM alpine:3.21

# neovim + git for plugin install, sqlite for sqlite.lua, curl for LLM calls
# (Tier 1 tests mock the LLM, so no token is needed at build/test time).
RUN apk add --no-cache neovim git sqlite-dev curl

WORKDIR /plugin
COPY . .

# Install plugin dependencies (nui.nvim, sqlite.lua) ahead of time.
# install_deps.lua exits non-zero unless every dependency is loadable, so the
# build fails here if the image would be unusable.
RUN nvim --headless -u test/install_deps.lua \
    -c "Lazy! sync" -c "qa!" 2>&1

# Run the Tier 1 deterministic suite in an isolated workspace.
ENV KB_WORKSPACE=/tmp/kb-workspace
CMD ["nvim", "--headless", "-u", "dev/init.lua", "-l", "test/test_flow.lua"]
