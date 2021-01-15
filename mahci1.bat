@echo off
jwasm -nologo -pe -Sg -Fl ahci1.asm
pestub -n -x -q ahci1.exe loadpe.bin
