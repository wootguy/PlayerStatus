cd "C:\Games\Steam\steamapps\common\Sven Co-op\svencoop\addons\metamod\dlls"

if exist PlayerStatus_old.dll (
    del PlayerStatus_old.dll
)
if exist PlayerStatus.dll (
    rename PlayerStatus.dll PlayerStatus_old.dll 
)

exit /b 0