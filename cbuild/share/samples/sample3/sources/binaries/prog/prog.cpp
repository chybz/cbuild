#include <iostream>

#include <sample3/config.h>
#include <sample3/system_config.hpp>

int main(int ac, char ** av)
{
    sample3::system_config conf;
    sample3::system_config::plugin_list plugins;

    std::cout << "bin is: " << conf.bin_dir() << std::endl;
    std::cout << "etc is: " << conf.get_dir("etc") << std::endl;

    unsigned int plugin_count = conf.find_plugins(plugins);

    std::cout << "found " << plugin_count << " plugins" << std::endl;

    for (unsigned int i = 0; i < plugin_count; i++) {
	std::cout << plugins[i] << std::endl;
    }

    return 0;
}

#if 0
=pod

=head1 NAME

prog - a sample cbuild program

=head1 DESCRIPTION

prog is a very interesting program that does nothing

=head1 SYNOPSIS

  prog

=cut
#endif
