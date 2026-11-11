; Virtual cameras:
;   Softcam (DirectShow, 64-bit and 32-bit) for classic apps
;   LiveChar Camera (Media Foundation, Windows 11) for every app

!macro stopCameraServices
  ; The Windows camera services keep the camera DLL loaded; stop them so it can be replaced.
  ; They start again by themselves the next time any app opens a camera.
  nsExec::ExecToLog '"$WINDIR\Sysnative\sc.exe" stop FrameServerMonitor'
  nsExec::ExecToLog '"$WINDIR\Sysnative\sc.exe" stop FrameServer'
!macroend

!macro customInit
  !insertmacro stopCameraServices
!macroend

!macro customInstall
  nsExec::ExecToLog '"$WINDIR\Sysnative\regsvr32.exe" /s "$INSTDIR\resources\softcam\x64\softcam.dll"'
  nsExec::ExecToLog '"$WINDIR\SysWOW64\regsvr32.exe" /s "$INSTDIR\resources\softcam\Win32\softcam.dll"'
  nsExec::ExecToLog '"$WINDIR\Sysnative\regsvr32.exe" /s "$INSTDIR\resources\wincam\LiveCharCamSource.dll"'
!macroend

!macro customUnInit
  !insertmacro stopCameraServices
  nsExec::ExecToLog '"$WINDIR\Sysnative\regsvr32.exe" /u /s "$INSTDIR\resources\softcam\x64\softcam.dll"'
  nsExec::ExecToLog '"$WINDIR\SysWOW64\regsvr32.exe" /u /s "$INSTDIR\resources\softcam\Win32\softcam.dll"'
  nsExec::ExecToLog '"$WINDIR\Sysnative\regsvr32.exe" /u /s "$INSTDIR\resources\wincam\LiveCharCamSource.dll"'
!macroend
