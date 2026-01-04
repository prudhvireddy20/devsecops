import os

def run_command(cmd):
    os.system(cmd)  # dangerous

def login():
    password = "admin123"  # hardcoded secret
    return password

def execute(expr):
    eval(expr)  # insecure
