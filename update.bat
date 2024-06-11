@echo off
setlocal enabledelayedexpansion

set BATCH_SIZE=127
setlocal
set "FILES="
for /f "tokens=*" %%i in ('git status --porcelain ^| awk "{print $2}"') do (
    set "FILES=!FILES! %%i"
)
endlocal & set FILES=%FILES:~1%

set TOTAL_FILES=0
for %%i in (%FILES%) do (
    set /A TOTAL_FILES+=1
)

set START=0
:batch_loop
if %START% geq %TOTAL_FILES% goto end

set /A END=%START% + %BATCH_SIZE%
if %END% geq %TOTAL_FILES% set END=%TOTAL_FILES%

echo Staging files from %START% to %END%
set "ADD_CMD=git add"
set "FILES_BATCH="
for /L %%i in (%START%,1,%END%) do (
    for %%f in (%FILES%) do (
        set "ADD_CMD=!ADD_CMD! %%f"
        set "FILES_BATCH=!FILES_BATCH! %%f"
        set /A START+=1
        if !START! geq %END% goto break_loop
    )
)
:break_loop
%ADD_CMD%
git commit -m "Committing batch from %START% to %END%"
git push

goto batch_loop
:end
echo All batches committed and pushed.
endlocal
