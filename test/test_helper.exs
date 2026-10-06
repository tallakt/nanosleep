# Some tests look at the program from outside with kill, which Windows hasn't.
exclude = if match?({:win32, _}, :os.type()), do: [:unix], else: []
# And one asks for a SCHED_FIFO priority, which only Linux has.
exclude = if :os.type() == {:unix, :linux}, do: exclude, else: [:linux | exclude]
ExUnit.start(exclude: exclude)
