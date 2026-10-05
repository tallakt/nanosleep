# Some tests look at the program from outside with kill, which Windows hasn't.
exclude = if match?({:win32, _}, :os.type()), do: [:unix], else: []
ExUnit.start(exclude: exclude)
