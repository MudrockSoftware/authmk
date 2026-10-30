# The licensed tests share the library's setup.
if !Application.get_env(:authmk, :test_helper_loaded) do
  Code.require_file("../../test/test_helper.exs", __DIR__)
end
