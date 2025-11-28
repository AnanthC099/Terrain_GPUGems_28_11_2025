cls

del *.exe *.txt *.obj *.pdb *.res *.spv *.ilk

glslangValidator.exe -V -H -o Shader.vert.spv Shader.vert

glslangValidator.exe -V -H -o Shader.frag.spv Shader.frag

glslangValidator.exe -V -H -o Shader.tesc.spv Shader.tesc

glslangValidator.exe -V -H -o Shader.tese.spv Shader.tese

cl /I"C:\VulkanSDK\Anjaneya\Include" /c /Zi /EHsc Vk.cpp /Fo"Vk.obj"

rc.exe Vk.rc

link Vk.obj Vk.res /LIBPATH:"C:\VulkanSDK\Anjaneya\Lib" vulkan-1.lib gdi32.lib user32.lib kernel32.lib /OUT:Vk.exe /DEBUG

del Vk.obj Vk.res

Vk.exe

