#
# Copyright 2017 (c) Andrey Galkin
#


define cfweb::deploy::citool(
    String[1] $site,
    String[1] $run_user,
    String[1] $deploy_user,
    String[1] $site_dir,
    String[1] $persistent_dir,
    Array[String[1]] $apps,

    Enum[
        'svn',
        'git',
        'hg',
        'archiva',
        'artifactory',
        'nexus',
        'sftp'
    ] $type,
    String[1] $url,

    Boolean $find_latest = true,
    Integer[0] $depth = 0,
    Optional[String[1]] $match = undef,
    Enum[
        'symcode',
        'natural',
        'ctime',
        'mtime'
    ] $sort = 'natural',

    Boolean $is_tarball = true,
) {
    require cfweb::appcommon::citool
}