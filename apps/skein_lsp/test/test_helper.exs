# GenLSP's buffer calls System.stop() when its transport closes
# (exit_on_end). Test clients open and close TCP connections constantly,
# which would halt the VM mid-suite.
Application.put_env(:gen_lsp, :exit_on_end, false)

# LSP round-trips go over real TCP; the 100ms default is flaky under load.
ExUnit.start(assert_receive_timeout: 1_000)
