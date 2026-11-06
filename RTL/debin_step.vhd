library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;

use work.cabac_types_pkg.all;

entity Debin_step is
    generic (
        N : positive := 1
    );
    port (
        state_in : in debin_work_state_t;

        ctx_id      : out integer range 0 to 3;
        bypass_mode : out std_logic;

        decoded_bit : in std_logic;
        enable      : in std_logic;

        state_out : out debin_work_state_t;

        symbol_out  : out integer;
        symbol_done : out std_logic
    );
end entity;

architecture rtl of Debin_step is
begin

    process(state_in)
    begin
        ctx_id      <= 0;
        bypass_mode <= '0';

        case state_in.state is
            when DB_SIG =>
                ctx_id      <= 0;
                bypass_mode <= '0';

            when DB_SIGN =>
                ctx_id      <= 1;
                bypass_mode <= '0';

            when DB_ABSGR =>
                ctx_id      <= 2;
                bypass_mode <= '0';

            when DB_UNARY =>
                ctx_id      <= 3;
                bypass_mode <= '0';

            when DB_BYPASS =>
                ctx_id      <= 0;
                bypass_mode <= '1';

            when others =>
                ctx_id      <= 0;
                bypass_mode <= '0';
        end case;
    end process;


    process(all)
        variable work_v : debin_work_state_t;

        variable threshold      : integer;
        variable last_threshold : integer;
        variable final_abs      : integer;
        variable m_val          : integer;

        variable remainder_next : unsigned(29 downto 0);

        variable symbol_v : integer;
        variable done_v   : std_logic;
    begin
        work_v := state_in;

        symbol_v := 0;
        done_v   := '0';

        if enable = '1' then
            case work_v.state is

                when DB_SIG =>
                    if decoded_bit = '0' then
                        symbol_v := 0;
                        work_v.state := DB_DONE;
                        done_v := '1';
                    else
                        work_v.state := DB_SIGN;
                    end if;


                when DB_SIGN =>
                    work_v.sign_neg := decoded_bit;
                    work_v.absgr := 1;
                    work_v.state := DB_ABSGR;


                when DB_ABSGR =>
                    threshold := 2 + (work_v.absgr - 1);

                    if decoded_bit = '0' then
                        final_abs := threshold - 1;

                        if work_v.sign_neg = '1' then
                            symbol_v := -final_abs;
                        else
                            symbol_v := final_abs;
                        end if;

                        work_v.state := DB_DONE;
                        done_v := '1';

                    else
                        if work_v.absgr < N then
                            work_v.absgr := work_v.absgr + 1;
                            work_v.state := DB_ABSGR;
                        else
                            work_v.unary := (others => '0');
                            work_v.bypass_left := (others => '0');
                            work_v.remainder := (others => '0');
                            work_v.state := DB_UNARY;
                        end if;
                    end if;


                when DB_UNARY =>
                    if decoded_bit = '0' then

                        if work_v.unary =
                           to_unsigned(0, work_v.unary'length)
                        then
                            last_threshold := 2 + (N - 1);
                            final_abs := last_threshold;

                            if work_v.sign_neg = '1' then
                                symbol_v := -final_abs;
                            else
                                symbol_v := final_abs;
                            end if;

                            work_v.state := DB_DONE;
                            done_v := '1';

                        else
                            work_v.bypass_left := work_v.unary;
                            work_v.remainder := (others => '0');
                            work_v.state := DB_BYPASS;
                        end if;

                    else

                        if work_v.unary <
                           to_unsigned(30, work_v.unary'length)
                        then
                            work_v.unary := work_v.unary + 1;
                            work_v.state := DB_UNARY;
                        else
                            work_v.unary := to_unsigned(30, 5);
                            work_v.bypass_left := to_unsigned(30, 5);
                            work_v.remainder := (others => '0');
                            work_v.state := DB_BYPASS;
                        end if;
                    end if;


                when DB_BYPASS =>
                    remainder_next :=
                        work_v.remainder(28 downto 0) &
                        decoded_bit;

                    work_v.remainder := remainder_next;

                    if work_v.bypass_left >
                       to_unsigned(1, work_v.bypass_left'length)
                    then
                        work_v.bypass_left :=
                            work_v.bypass_left - 1;

                        work_v.state := DB_BYPASS;

                    else
                        last_threshold := 2 + (N - 1);

                        m_val :=
                            (2 ** to_integer(work_v.unary))
                            - 1
                            + to_integer(remainder_next);

                        final_abs :=
                            last_threshold + m_val;

                        if work_v.sign_neg = '1' then
                            symbol_v := -final_abs;
                        else
                            symbol_v := final_abs;
                        end if;

                        work_v.state := DB_DONE;
                        done_v := '1';
                    end if;


                when DB_IDLE =>
                    null;

                when DB_DONE =>
                    null;

            end case;
        end if;

        state_out   <= work_v;
        symbol_out  <= symbol_v;
        symbol_done <= done_v;
    end process;

end architecture;
