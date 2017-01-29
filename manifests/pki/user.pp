#
# Copyright 2016-2017 (c) Andrey Galkin
#


class cfweb::pki::user {
    assert_private()

    $user = $cfweb::pki::ssh_user
    $home_dir = "/home/${user}"

    group { $user:
        ensure => present,
    } ->
    user { $user:
        ensure         => present,
        home           => $home_dir,
        gid            => $user,
        groups         => ['ssh_access'],
        managehome     => true,
        shell          => '/bin/bash',
        purge_ssh_keys => true,
    }

    file {"/etc/sudoers.d/${user}":
        group   => root,
        owner   => root,
        mode    => '0400',
        replace => true,
        content => "
${user}   ALL=(ALL:ALL) NOPASSWD: /bin/systemctl reload ${cfweb::web_service}.service
",
        require => Package['sudo'],
    }

    # Own key
    #---
    $ssh_key_type = $cfweb::pki::ssh_key_type
    $ssh_key_bits = $cfweb::pki::ssh_key_bits
    $ssh_dir = "${home_dir}/.ssh"
    $ssh_idkey = "${ssh_dir}/id_${ssh_key_type}"

    exec { "cfdb_genkey@${user}":
        command => "/usr/bin/ssh-keygen -q -t ${ssh_key_type} -b ${ssh_key_bits} -P '' -f ${ssh_idkey}",
        creates => $ssh_idkey,
        user    => $user,
        group   => $user,
        require => User[$user],
    } ->
    file { "${ssh_dir}/config":
        owner   => $user,
        group   => $user,
        content => [
            'StrictHostKeyChecking no',
            "IdentityFile ${ssh_idkey}",
            'ConnectTimeout 5',
        ].join("\n")
    }

    # Accepted keys
    #---
    $ihost = undef # make buggy puppet-lint happy
    $info = undef
    $cfweb::cluster_hosts.each() |$ihost, $info| {
        if $ihost != $::trusted['certname'] {
            $host_under = regsubst($ihost, '\.', '_', 'G')

            cfnetwork::client_port { "any:cfssh:cfweb_${host_under}":
                dst  => $ihost,
                user => $user,
            }
            cfnetwork::service_port { "any:cfssh:cfweb_${host_under}":
                src => $ihost,
            }

            pick($info['ssh_keys'], {}).each |$kn, $kv| {
                ssh_authorized_key { "${user}:${kn}@${ihost}":
                    user    => $user,
                    type    => $kv['type'],
                    key     => $kv['key'],
                    require => User[$user],
                }
            }
        }
    }
}
