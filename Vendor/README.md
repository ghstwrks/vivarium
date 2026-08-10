# Vendored upstream sources

## `RunningMacOSInAVirtualMachineOnAppleSilicon`

Apple sample code, retrieved from
<https://developer.apple.com/documentation/virtualization/running-macos-in-a-virtual-machine-on-apple-silicon>.

Upstream commit: `32fd50d874b6bab37b146eef14153fa8ccf6d111`

Only the files needed as a baseline for this proof of concept were copied:

```text
LICENSE.txt
InstallationTool.entitlements
Swift/InstallationTool/main.swift
Swift/InstallationTool/MacOSVirtualMachineInstaller.swift
Swift/InstallationTool/MacOSRestoreImage.swift
Swift/Common/Path.swift
Swift/Common/MacOSVirtualMachineConfigurationHelper.swift
Swift/Common/MacOSVirtualMachineDelegate.swift
```

These files are the pristine upstream reference. They are **not** compiled: the
Swift package under `Sources/` contains the derived implementation. Keep this
directory unmodified so the diff against upstream stays legible, and see
`LICENSE.txt` for Apple's licensing terms covering the derived code.
