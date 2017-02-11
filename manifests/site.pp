#
# Copyright 2016-2017 (c) Andrey Galkin
#


define cfweb::site (
    String[1] $server_name = $title,
    Array[String[1]] $alt_names = [],
    Boolean $redirect_alt_names = true,

    Array[String[1]] $ifaces = ['main'],
    Array[Integer[1,65535]] $plain_ports = [80],
    Array[Integer[1,65535]] $tls_ports = [443],
    Boolean $redirect_plain = true,

    Boolean $is_backend = false,

    Hash[String[1],Hash] $auto_cert = {},
    Array[String[1]] $shared_certs = [],
    Hash[String[1],Hash] $dbaccess = {},
    Hash[String[1],Hash,1] $apps = { 'static' => {} },
    Optional[String[1]] $custom_conf = undef,
    String[1] $web_root = '/',

    Integer[1,25600] $cpu_weight = 100,
    Integer[1,200] $io_weight = 100,

    Hash[String[1], Struct[{
        type       => Enum['conn', 'req'],
        var        => String[1],
        count      => Optional[Integer[1]],
        entry_size => Optional[Integer[1]],
        rate       => Optional[String[1]],
        burst      => Optional[Integer[0]],
        nodelay    => Optional[Boolean],
        newname    => Optional[String[1]],
    }]] $limits = {},

    Optional[Hash[String[1], Any]] $deploy = undef,
    Optional[String[1]] $force_user = undef,
) {
    include cfdb
    include cfweb::nginx

    validate_re($title, '^[a-z][a-z0-9_]*$')

    #---
    if !$shared_certs and size($tls_ports) > 0 {
        $auto_cert_name = "auto__${server_name}"
        create_resources(
            'cfweb::pki::cert',
            {
                $auto_cert_name => {
                    'cert_name' => $server_name,
                }
            },
            $auto_cert
        )
        $dep_certs = [$auto_cert_name]
    } elsif $shared_certs {
        $shared_certs.each |$v| {
            if !defined(Cfweb::Pki::Cert[$v]) {
                fail("Please make sure Cfweb::Pki::Cert[${v}] is defined for use in ${title}")
            }
        }
        $dep_certs = $shared_certs
    }

    # Default hosts configure listen socket
    #---
    $iface = undef # make buggy puppet-lint happy
    $ifaces.each |$iface| {
        $plain = $plain_ports.each |$port| {
            ensure_resource('cfweb::nginx::defaulthost', "${iface}:${port}", {
                iface      => $iface,
                port       => $port,
                tls        => false,
                is_backend => $is_backend,
            })
        }
        $tls = $tls_ports.each |$port| {
            ensure_resource('cfweb::nginx::defaulthost', "${iface}:${port}", {
                iface      => $iface,
                port       => $port,
                tls        => true,
                is_backend => $is_backend,
                require    => Cfweb::Pki::Cert[$dep_certs],
            })
        }
    }

    # Basic file structure
    #---
    $site = "app_${title}"
    $is_dynamic = (size(keys($apps) - ['static']) > 0)
    $user = $force_user ? {
        undef => $is_dynamic ? {
            true => $site,
            default => $cfweb::nginx::user
        },
        default => $force_user,
    }
    $group = $user
    $deploy_user = "deploy_${title}"

    $site_dir = "${cfweb::nginx::web_dir}/${site}"
    $tmp_dir = "${site_dir}/tmp"
    $persistent_dir = "${cfweb::nginx::persistent_dir}/${site}"
    $conf_prefix = "${cfweb::nginx::sites_dir}/${site}"
    # This must be created by deploy script
    $document_root = "${site_dir}/current"

    if $is_dynamic or $deploy {
        ensure_resource('exec', "add_nginx_to_${group}", {
            command  => [
                "/usr/sbin/adduser ${cfweb::nginx::user} ${group}",
                "/bin/systemctl reload ${cfweb::nginx::service_name}"
            ].join(' && '),
            'unless' => "/usr/bin/id -Gn ${cfweb::nginx::user} | /bin/grep -q ${group}",
            require  => Group[$group],
        })
    }

    if $is_dynamic {
        ensure_resource('group', $group, { ensure => present })
        ensure_resource( 'user', $user, {
            ensure  => present,
            gid     => $group,
            home    => $site_dir,
            require => Group[$group],
        })

        file { [
                "${cfweb::nginx::bin_dir}/start-${title}",
                "${cfweb::nginx::bin_dir}/stop-${title}",
                "${cfweb::nginx::bin_dir}/restart-${title}",
                "${cfweb::nginx::bin_dir}/reload-${title}",
            ]:
            ensure => link,
            target => $cfweb::nginx::generic_control
        }
    }

    if $deploy {
        ensure_resource('group', $group, { ensure => present })
        ensure_resource( 'user', $deploy_user, {
            ensure  => present,
            gid     => $group,
            home    => $site_dir,
            require => Group[$group],
        })
    }

    file { $site_dir:
        ensure  => directory,
        mode    => '0750',
        owner   => $user,
        group   => $group,
        require => User[$user],
    }

    file { $document_root:
        ensure  => link,
        replace => false,
        target  => $cfweb::nginx::empty_root,
    }

    if $is_dynamic or $deploy {
        file { [$persistent_dir, $tmp_dir]:
            ensure  => directory,
            mode    => '0750',
            owner   => $user,
            group   => $group,
            require => User[$user],
        }
    }


    # DB access
    #---
    if $is_dynamic and $dbaccess {
        $dbaccess_deps = ($dbaccess.map |$k, $da| {
            $name = "${title}:${k}"
            create_resources(
                'cfdb::access',
                { $name => {
                    local_user    => $user,
                    custom_config => 'cfweb::appcommon::dbaccess',
                } },
                merge({
                    # TODO: get rid of facts
                    max_connections => pick_default(
                        $::facts.dig('cfweb', 'sites', $site, 'maxconn'),
                        $cfdb::max_connections_default
                    ),
                }, $da)
            )
            $name
        })


        $dbaccess_app_deps = ($apps.reduce({}) |$memo, $v| {
            $app = $v[0]
            $app_info = $v[1]
            $app_type = split($app, ':')[-1]

            $names = pick($app_info['dbaccess'], {}).map |$k, $da| {
                    $name = "${title}-${app_type}:${k}"
                    create_resources(
                        'cfdb::access',
                        { $name => {
                            local_user    => $user,
                            custom_config => 'cfweb::appcommon::dbaccess',
                        } },
                        merge({
                            # TODO: get rid of facts
                            max_connections => pick_default(
                                $::facts.dig(
                                    'cfweb', 'sites', $site,
                                    'apps', $app_type, 'maxconn'
                                ),
                                $cfdb::max_connections_default
                            ),
                        }, $da)
                    )
                    $name
                }

            merge($memo, { $app => $names })
        })
    } else {
        $dbaccess_deps = []
        $dbaccess_app_deps = {}
    }

    # Define apps
    #---
    $cfg_notify = [
        Service[$cfweb::nginx::service_name],
    ]

    if $is_dynamic {
        # Define global app slice
        cfweb_app { $user:
            ensure     => present,
            type       => 'global',
            site       => $title,
            user       => $user,
            site_dir   => $site_dir,

            cpu_weight => $cpu_weight,
            io_weight  => $io_weight,

            misc       => {},
        }
    }

    $apps.each |$app, $app_info| {
        $puppet_type = size(split($app, ':')) ? {
            1       => "cfweb::app::${app}",
            default => $app,
        }

        $app_dbaccess_deps = $dbaccess_deps +
                pick($dbaccess_app_deps[$app], [])

        create_resources(
            $puppet_type,
            {
                $title => {
                    site           => $title,
                    user           => $user,
                    site_dir       => $site_dir,
                    conf_prefix    => $conf_prefix,
                    type           => split($app, ':')[-1],
                    dbaccess_names => $app_dbaccess_deps,
                    require        =>
                        Cfweb::Appcommon::Dbaccess[$app_dbaccess_deps],
                    notify         => $cfg_notify,
                },
            },
            $app_info
        )
    }

    # Create vhost file
    #---
    if size($dep_certs) {
        include cfweb::pki

        $certs = $dep_certs.map |$cert_name| {
            getparam(Cfweb::Pki::Certinfo[$cert_name], 'info')
        }
    } else {
        $certs = []
    }

    $bind = $ifaces.map |$iface| {
        $iface ? {
            'any' => '*',
            default => cf_get_bind_address($iface),
        }
    }

    $trusted_proxy = $is_backend ? {
        true => any2array($cfweb::nginx::trusted_proxy),
        default => undef
    }

    file { "${conf_prefix}.conf":
        mode    => '0640',
        content => epp('cfweb/app_vhost.epp', {
            site               => $title,
            conf_prefix        => $conf_prefix,

            server_name        => $server_name,
            alt_names          => $alt_names,
            redirect_alt_names => $redirect_alt_names,
            bind               => $bind,
            plain_ports        => $plain_ports,
            tls_ports          => $tls_ports,
            redirect_plain     => $redirect_plain,
            proxy_protocol     => $is_backend,
            trusted_proxy      => $trusted_proxy,

            certs              => $certs,
            apps               => keys($apps),

            custom_conf        => pick_default($custom_conf, ''),
        }),
        notify  => $cfg_notify,
    }

    # Deploy procedure
    #---
    if $deploy {
        cfweb::deploy { $title:
            strategy       => pick($deploy['strategy'], 'citool'),
            params         => $deploy - strategy,
            site           => $title,
            run_user       => $user,
            deploy_user    => $deploy_user,
            site_dir       => $site_dir,
            apps           => keys($apps),
            persistent_dir => $persistent_dir,
            # Note: it must run AFTER the rest is configured
            require        => $cfg_notify,
        }
    }
}
