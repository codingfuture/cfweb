#
# Copyright 2016-2017 (c) Andrey Galkin
#


define cfweb::pki::cert(
    $cert_name = $title,
    $key_name = undef,
    $cert_source = undef,
    Optional[String[2,2]]
        $x509_c = undef,
    Optional[String[1]]
        $x509_st = undef,
    Optional[String[1]]
        $x509_l = undef,
    Optional[String[1]]
        $x509_o = undef,
    Optional[String[1]]
        $x509_ou = undef,
    Optional[String[1]]
        $x509_cn = undef,
){
    include cfweb::pki

    $key_name_act = pick($key_name, $cfweb::pki::key_name)
    $exec_name = "cfweb::pki::cert::${cert_name}"
    $key_file = "${cfweb::pki::key_dir}/${key_name_act}.key"
    $cert_base = "${cfweb::pki::cert_dir}/${cert_name}"
    $crt_file = "${cert_base}.crt"
    $csr_file = "${cert_base}.csr"
    $trusted_file = "${crt_file}.trusted"
    $pki_user = $cfweb::pki::ssh_user

    if $cfweb::is_secondary {
        exec { $exec_name:
            command => '/bin/true',
            creates => $crt_file,
            notify  => Exec['cfweb_sync_pki']
        }
    } else {
        if $key_name_act != $cfweb::pki::key_name {
            $key_info = $cfweb::global::keys[$key_name_act]

            if $key_info {
                ensure_resource('cfweb::pki::key', $key_name_act, $key_info)
            } else {
                fail("Please define cfweb::global::keys[${key_name_act}]")
            }
        }

        $x_c = pick($x509_c, $cfweb::pki::x509_c)
        $x_st = pick($x509_st, $cfweb::pki::x509_st)
        $x_l = pick($x509_l, $cfweb::pki::x509_l)
        $x_o = pick($x509_o, $cfweb::pki::x509_o)
        $x_ou = pick($x509_ou, $cfweb::pki::x509_ou)
        $x_cn = pick($x509_cn, $cert_name)

        # CSR must always be available
        $csr_exec = "${exec_name}::csr"
        exec { $csr_exec:
            command => [
                "${cfweb::pki::openssl} req",
                "-out ${csr_file}",
                "-key ${key_file}",
                '-new -sha256',
                "-subj '/C=${x_c}/ST=${x_st}/L=${x_l}/O=${x_o}/OU=${x_ou}/CN=${x_cn}'",
            ].join(' '),
            creates => $csr_file,
            require => Exec["cfweb::pki::key::${key_name_act}"],
            notify  => Exec['cfweb_sync_pki']
        }
        -> file { $csr_file:
            owner   => $pki_user,
            group   => $pki_user,
            mode    => '0640',
            replace => no,
            content => '',
        }

        #---
        $cert_source_act = pick_default($cert_source, $cfweb::pki::cert_source)

        $dyn_cert = $cert_source_act ? {
            'acme' => true,
            #'wosign' => true,
            default => false,
        }

        #---
        if $dyn_cert {
            require "cfweb::pki::${cert_source_act}"

            exec { "${exec_name}.${cert_source_act}":
                command => [
                    getvar("cfweb::pki::${cert_source_act}::command"),
                    $key_file,
                    $csr_file,
                    $crt_file,
                ].join(' '),
                creates => "${crt_file}.${cert_source_act}",
                require => Exec[$csr_exec],
                # no notify, sync should be done internally
            }
            -> file { $crt_file:
                owner   => $pki_user,
                group   => $pki_user,
                mode    => '0640',
                replace => no,
                content => '',
            }
            -> file { $trusted_file:
                owner   => $pki_user,
                group   => $pki_user,
                mode    => '0640',
                replace => no,
                content => '',
            }
        } elsif $cert_source {
            $certs = cfweb::build_cert_chain(file($cert_source), $x_cn)

            file { $crt_file:
                content   => $certs['chained'].join("\n"),
                owner     => $pki_user,
                group     => $pki_user,
                mode      => '0640',
                show_diff => false,
                notify    => Exec['cfweb_sync_pki'],
            }

            file { $trusted_file:
                content   => $certs['trusted'].join("\n"),
                owner     => $pki_user,
                group     => $pki_user,
                mode      => '0640',
                show_diff => false,
                notify    => Exec['cfweb_sync_pki'],
            }
        } else {
            exec { $exec_name:
                command => [
                    "${cfweb::pki::openssl} x509",
                    '-req -days 3650',
                    "-in ${csr_file}",
                    "-signkey ${key_file}",
                    "-out ${crt_file}",
                ].join(' '),
                creates => $crt_file,
                require => Exec[$csr_exec],
                notify  => Exec['cfweb_sync_pki'],
            }
            -> file { $crt_file:
                owner   => $pki_user,
                group   => $pki_user,
                mode    => '0640',
                replace => no,
                content => '',
            }
        }
    }
}
