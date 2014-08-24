#include <iostream>

namespace my_plugin {

int my_plugin_func(void)
{
    std::cout << "my_plugin_func() called" << std::endl;

    return 0;
}

} // namespace my_plugin
