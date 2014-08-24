#include <iostream>

#include <prog_utils/utils.hpp>
#include <msgpack.hpp>

namespace prog_utils {

int
a_class::method(void)
{
    std::cout << "a_class::method() called" << std::endl;

    return 0;
}

} // namespace prog_utils
