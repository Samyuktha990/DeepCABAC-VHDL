library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;

use work.cabac_types_pkg.all;

entity Context_step is
    generic (
        NUM_CTX   : positive := 4;
        MAX_TOTAL : positive := 64
    );
    port (
        c0_mem_in : in ctx_array_t(0 to NUM_CTX-1);
        c1_mem_in : in ctx_array_t(0 to NUM_CTX-1);

        ctx_id      : in integer range 0 to NUM_CTX-1;
        bypass_mode : in std_logic;

        c0_selected : out count_t;
        c1_selected : out count_t;

        decoded_bit  : in std_logic;
        update_enable : in std_logic;

        c0_mem_out : out ctx_array_t(0 to NUM_CTX-1);
        c1_mem_out : out ctx_array_t(0 to NUM_CTX-1)
    );
end entity;

architecture rtl of Context_step is
begin

    c0_selected <=
        to_unsigned(1, 7)
        when bypass_mode = '1'
        else c0_mem_in(ctx_id);

    c1_selected <=
        to_unsigned(1, 7)
        when bypass_mode = '1'
        else c1_mem_in(ctx_id);

    process(all)
        variable c0_v : ctx_array_t(0 to NUM_CTX-1);
        variable c1_v : ctx_array_t(0 to NUM_CTX-1);

        variable c0_i    : integer;
        variable c1_i    : integer;
        variable new_c0  : integer;
        variable new_c1  : integer;
        variable total_i : integer;
    begin
        c0_v := c0_mem_in;
        c1_v := c1_mem_in;

        if (update_enable = '1') and (bypass_mode = '0') then
            c0_i := to_integer(c0_v(ctx_id));
            c1_i := to_integer(c1_v(ctx_id));

            if decoded_bit = '0' then
                new_c0 := c0_i + 1;
                new_c1 := c1_i;
            else
                new_c0 := c0_i;
                new_c1 := c1_i + 1;
            end if;

            total_i := new_c0 + new_c1;

            if total_i > MAX_TOTAL then
                new_c0 := (new_c0 + 1) / 2;
                new_c1 := (new_c1 + 1) / 2;
            end if;

            if new_c0 < 1 then
                new_c0 := 1;
            elsif new_c0 > 127 then
                new_c0 := 127;
            end if;

            if new_c1 < 1 then
                new_c1 := 1;
            elsif new_c1 > 127 then
                new_c1 := 127;
            end if;

            c0_v(ctx_id) := to_unsigned(new_c0, 7);
            c1_v(ctx_id) := to_unsigned(new_c1, 7);
        end if;

        c0_mem_out <= c0_v;
        c1_mem_out <= c1_v;
    end process;

end architecture;
