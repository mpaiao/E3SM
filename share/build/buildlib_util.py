
from CIME.utils import run_cmd
from CIME.build import get_standard_makefile_args

###############################################################################
def get_macro_var(macro_dump, varname):
###############################################################################
    look_for = f"{varname} :="
    for line in macro_dump.splitlines():
        if line.startswith(look_for):
            return line.split(":=")[-1].strip()

    return ""

###############################################################################
def extract_from_macros(case, comp_name, extra_vars=()):
###############################################################################
    """
    Hacky way of getting stuff from Macros. We use the $case/Macros.make file,
    which gets generated by CIME case.build and run it with -p to print all the
    variables it sets. This is currently the best method we have to query macro
    settings outside of CMake. It handles the COMP_NAME conditionals correctly,
    allowing us to customize things for specific sharedlibs.
    """
    standard_vars = ["SFC", "SCC", "SCXX",
                     "MPIFC", "MPICC", "MPICXX",
                     "CMAKE_Fortran_FLAGS", "CMAKE_C_FLAGS", "CMAKE_CXX_FLAGS",
                     "CPPDEFS", "CMAKE_EXE_LINKER_FLAGS"]
    all_vars = standard_vars + list(extra_vars)

    make_args = get_standard_makefile_args(case, shared_lib=True)
    macro_dump = run_cmd(f"make -f Macros.make COMP_NAME={comp_name} {make_args} -p")[1]

    result = []
    for macro_var in all_vars:
        macro_val = get_macro_var(macro_dump, macro_var)
        result.append(macro_val)

    return result