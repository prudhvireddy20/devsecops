// vuln.c
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

int main(int argc, char *argv[]) {
    char buffer[10];
    strcpy(buffer, argv[1]); // Buffer Overflow

    system(argv[1]); // Command Injection
    return 0;
}
