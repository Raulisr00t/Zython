def fib(n):
    if n < 2:
        return n
    return fib(n - 1) + fib(n - 2)


i = 0
while i < 10:
    print(fib(i))
    i += 1
