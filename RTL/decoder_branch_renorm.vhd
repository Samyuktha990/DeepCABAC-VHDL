library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;

use work.cabac_types_pkg.all;

entity Decoder_branch_renorm is
    generic (
        STREAM_WIDTH : positive := 256
    );
    port (
        enable : in std_logic;
        state_in : in arithmetic_state_t;
        split_in : in unsigned(32 downto 0);
        forced_bin : in std_logic;
        bits_in : in std_logic_vector(STREAM_WIDTH-1 downto 0);
        valid_bits_in : in natural range 0 to STREAM_WIDTH;
        state_out : out arithmetic_state_t;
        success : out std_logic;
        need_bits : out std_logic
    );
end entity;

architecture experimental of Decoder_branch_renorm is
    constant HALF_C : unsigned(32 downto 0) :=
        shift_left(to_unsigned(1,33),31);

    constant QUARTER_C : unsigned(32 downto 0) :=
        shift_left(to_unsigned(1,33),30);

    constant THREE_QUARTER_C : unsigned(32 downto 0) :=
        shift_left(to_unsigned(3,33),30);
begin
    process(all)
        variable s : arithmetic_state_t;
        variable lo, hi, val : unsigned(32 downto 0);
        variable mid, offset : unsigned(32 downto 0);
        variable ptr : natural;
        variable e1, e2, e3 : boolean;
        variable finished, failed : boolean;
        variable next_bit : std_logic;
    begin
        state_out <= state_in;
        success <= '0';
        need_bits <= '0';

        if enable = '1' then
            s := state_in;
            lo := s.low_value;
            hi := s.high_value;
            val := s.code_value;
            ptr := s.bit_ptr;

            mid := lo + split_in;

            if forced_bin = '1' then
                lo := mid;
            else
                hi := mid;
            end if;

            finished := false;
            failed := false;

            for r in 0 to 8 loop
                if not finished and not failed then

                    -- Evaluate all three conditions
                    -- from the same current state.
                    e1 := (hi <= HALF_C);
                    e2 := (lo >= HALF_C);
                    e3 := (lo >= QUARTER_C) and
                          (hi <= THREE_QUARTER_C);

                    -- Original priority: E1, E2, E3.
                    if e1 then
                        offset := (others => '0');
                    elsif e2 then
                        offset := HALF_C;
                    elsif e3 then
                        offset := QUARTER_C;
                    else
                        finished := true;
                    end if;

                    if not finished then
                        if ptr >= valid_bits_in then
                            failed := true;
                        else
                            next_bit :=
                                bits_in(bits_in'high - integer(ptr));

                            ptr := ptr + 1;

                            lo := shift_left(lo - offset, 1);
                            hi := shift_left(hi - offset, 1);
                            val := shift_left(val - offset, 1);

                            val(0) := next_bit;
                        end if;
                    end if;
                end if;
            end loop;

            -- After exactly nine successful shifts,
            -- report need_bits without another condition check.
            if finished then
                s.low_value := lo;
                s.high_value := hi;
                s.code_value := val;
                s.bit_ptr := ptr;

                state_out <= s;
                success <= '1';
                need_bits <= '0';
            else
                success <= '0';
                need_bits <= '1';
            end if;
        end if;
    end process;
end architecture;