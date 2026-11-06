library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;

use work.cabac_types_pkg.all;

entity Decoder_step_splitbranch_ratio33_offsetcmp is
    generic (
        STREAM_WIDTH : positive := 256
    );

    port (
        enable : in std_logic;

        state_in : in arithmetic_state_t;

        c0_in : in count_t;
        c1_in : in count_t;

        bypass_mode : in std_logic;

        bits_in :
            in std_logic_vector(STREAM_WIDTH-1 downto 0);

        valid_bits_in :
            in natural range 0 to STREAM_WIDTH;

        decoded_bit : out std_logic;
        success     : out std_logic;
        need_bits   : out std_logic;

        state_out : out arithmetic_state_t
    );
end entity;


architecture rtl of Decoder_step_splitbranch_ratio33_offsetcmp is

    signal split_s :
        unsigned(32 downto 0);

    signal code_offset_s :
        unsigned(32 downto 0);

    signal actual_bin_s :
        std_logic;

    signal branch_state_s :
        arithmetic_state_t;

    signal branch_success_s :
        std_logic;

    ------------------------------------------------------------
    -- Safe split-engine inputs while enable = 0.
    --
    -- This avoids evaluating irrelevant/invalid context values
    -- when the original Decoder_step itself is disabled.
    ------------------------------------------------------------
    signal split_c0_s :
        unsigned(6 downto 0) := to_unsigned(1, 7);

    signal split_c1_s :
        unsigned(6 downto 0) := to_unsigned(1, 7);

    signal split_bypass_s :
        std_logic := '1';

begin

    split_c0_s <=
        c0_in when enable = '1'
        else to_unsigned(1, 7);

    split_c1_s <=
        c1_in when enable = '1'
        else to_unsigned(1, 7);

    split_bypass_s <=
        bypass_mode when enable = '1'
        else '1';


    ------------------------------------------------------------
    -- Exact reciprocal split calculation.
    ------------------------------------------------------------

    U_SPLIT : entity work.cabac_split_engine_ratio33_candidate
        port map (
            low_in      => state_in.low_value,
            high_in     => state_in.high_value,

            c0_in       => c0_in,
            c1_in       => c1_in,

            bypass_mode => split_bypass_s,

            split_out   => split_s
        );


    ------------------------------------------------------------
    -- Same bin decision as the frozen Decoder_step.
    ------------------------------------------------------------

    code_offset_s <=
        state_in.code_value - state_in.low_value;

    actual_bin_s <=
        '1'
        when (state_in.code_value >= state_in.low_value) and
             (code_offset_s >= split_s)
        else
        '0';


    ------------------------------------------------------------
    -- Apply only the selected arithmetic branch + renorm.
    ------------------------------------------------------------

    U_BRANCH : entity work.Decoder_branch_renorm
        generic map (
            STREAM_WIDTH => STREAM_WIDTH
        )
        port map (
            enable => enable,

            state_in => state_in,

            split_in   => split_s,
            forced_bin => actual_bin_s,

            bits_in       => bits_in,
            valid_bits_in => valid_bits_in,

            state_out => branch_state_s,

            success   => branch_success_s,
            need_bits => open
        );


    ------------------------------------------------------------
    -- Reproduce the exact external behaviour of frozen
    -- Decoder_step.
    ------------------------------------------------------------

    process(all)
    begin

        state_out   <= state_in;
        decoded_bit <= '0';
        success     <= '0';
        need_bits   <= '0';

        if enable = '1' then

            if branch_success_s = '1' then

                state_out   <= branch_state_s;
                decoded_bit <= actual_bin_s;
                success     <= '1';
                need_bits   <= '0';

            else

                state_out   <= state_in;
                decoded_bit <= '0';
                success     <= '0';
                need_bits   <= '1';

            end if;

        end if;

    end process;

end architecture;
