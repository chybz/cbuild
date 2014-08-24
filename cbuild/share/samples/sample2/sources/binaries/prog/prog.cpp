#include <iostream>

#include <sample2/config.h>
#include <sample2/system_config.hpp>

#include <prog_utils/utils.hpp>

int main(int ac, char ** av)
{
    prog_utils::a_class a;

    sample2::system_config conf;

    std::cout << "bin is: " << conf.bin_dir() << std::endl;
    std::cout << "etc is: " << conf.get_dir("etc") << std::endl;

    std::cout << "calling method" << std::endl;

    return a.method();
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
