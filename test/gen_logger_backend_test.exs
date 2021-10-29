defmodule GenLoggerBackendTest do
  use ExUnit.Case
  doctest GenLoggerBackend

  test "greets the world" do
    assert GenLoggerBackend.hello() == :world
  end
end
