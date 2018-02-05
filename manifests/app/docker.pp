#
# Copyright 2016-2018 (c) Andrey Galkin
#


define cfweb::app::docker (
    String[1] $site,
    String[1] $user,
    String[1] $site_dir,
    String[1] $conf_prefix,
    String[1] $type,
    Array[String[1]] $dbaccess_names,
    String[1] $template_global = 'cfweb/upstream_go',
    String[1] $template = 'cfweb/app_go',

    Integer[1] $memory_weight = 100,
    Optional[Integer[1]] $memory_max = undef,
    Cfsystem::CpuWeight $cpu_weight = 100,
    Cfsystem::IoWeight $io_weight = 100,
) {
    fail('Not implemented yet')
}
