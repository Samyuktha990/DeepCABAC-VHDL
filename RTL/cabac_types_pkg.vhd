library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;

package cabac_types_pkg is

    subtype count_t is unsigned(6 downto 0);

    type ctx_array_t is array (natural range <>) of count_t;

    type arithmetic_state_t is record
        low_value  : unsigned(32 downto 0);
        high_value : unsigned(32 downto 0);
        code_value : unsigned(32 downto 0);
        bit_ptr    : natural;
    end record;

    type debin_state_t is (
        DB_IDLE,
        DB_SIG,
        DB_SIGN,
        DB_ABSGR,
        DB_UNARY,
        DB_BYPASS,
        DB_DONE
    );

    type debin_work_state_t is record
        state       : debin_state_t;
        sign_neg    : std_logic;
        absgr       : integer;
        unary       : unsigned(4 downto 0);
        bypass_left : unsigned(4 downto 0);
        remainder   : unsigned(29 downto 0);
    end record;

end package;

package body cabac_types_pkg is
end package body;
