@{
    RootModule=''
    ModuleVersion='4.0.0'
    GUID='80ef332e-64a3-4cf9-b6e5-2a6c762c5c15'
    Author='Local AI Control Center'
    CompanyName='Community'
    Copyright='Copyright (c) 2026'
    Description='Modular Windows control plane for llama.cpp and coding harnesses.'
    PowerShellVersion='5.1'
    NestedModules=@(
        'Modules\Common.psm1',
        'Modules\Configuration.psm1',
        'Modules\Gguf.psm1',
        'Modules\Hardware.psm1',
        'Modules\Discovery.psm1',
        'Modules\Profiles.psm1'
    )
    FunctionsToExport='*'
    CmdletsToExport=@()
    VariablesToExport=@()
    AliasesToExport=@()
}
