; Register / unregister the Softcam DirectShow virtual camera (64-bit and 32-bit).
!macro customInstall
  nsExec::ExecToLog '"$WINDIR\Sysnative\regsvr32.exe" /s "$INSTDIR\resources\softcam\x64\softcam.dll"'
  nsExec::ExecToLog '"$WINDIR\SysWOW64\regsvr32.exe" /s "$INSTDIR\resources\softcam\Win32\softcam.dll"'
!macroend

!macro customUnInit
  nsExec::ExecToLog '"$WINDIR\Sysnative\regsvr32.exe" /u /s "$INSTDIR\resources\softcam\x64\softcam.dll"'
  nsExec::ExecToLog '"$WINDIR\SysWOW64\regsvr32.exe" /u /s "$INSTDIR\resources\softcam\Win32\softcam.dll"'
!macroend
