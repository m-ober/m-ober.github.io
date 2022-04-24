@echo off
set /p fn="Enter Filename: "
..\hugo.exe new posts/%fn%.md
