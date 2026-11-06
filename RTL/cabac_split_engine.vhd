library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;

entity cabac_split_engine_ratio33_candidate is
    port (
        low_in      : in  unsigned(32 downto 0);
        high_in     : in  unsigned(32 downto 0);

        c0_in       : in  unsigned(6 downto 0);
        c1_in       : in  unsigned(6 downto 0);

        bypass_mode : in  std_logic;

        split_out   : out unsigned(32 downto 0)
    );
end entity;


architecture rtl of cabac_split_engine_ratio33_candidate is

    ------------------------------------------------------------
    -- RECIP[d] = floor(2^39 / d)
    --
    -- Actual CABAC context guarantees:
    --     c0 >= 1
    --     c1 >= 1
    --     c0 + c1 <= 64
    --
    -- Therefore denominator d is in the range 2..64.
    ------------------------------------------------------------

    type recip_table_t is
        array (2 to 64) of unsigned(39 downto 0);

    constant RECIP_TABLE : recip_table_t := (
         2 => x"4000000000",
         3 => x"2AAAAAAAAA",
         4 => x"2000000000",
         5 => x"1999999999",
         6 => x"1555555555",
         7 => x"1249249249",
         8 => x"1000000000",
         9 => x"0E38E38E38",
        10 => x"0CCCCCCCCC",
        11 => x"0BA2E8BA2E",
        12 => x"0AAAAAAAAA",
        13 => x"09D89D89D8",
        14 => x"0924924924",
        15 => x"0888888888",
        16 => x"0800000000",
        17 => x"0787878787",
        18 => x"071C71C71C",
        19 => x"06BCA1AF28",
        20 => x"0666666666",
        21 => x"0618618618",
        22 => x"05D1745D17",
        23 => x"0590B21642",
        24 => x"0555555555",
        25 => x"051EB851EB",
        26 => x"04EC4EC4EC",
        27 => x"04BDA12F68",
        28 => x"0492492492",
        29 => x"0469EE5846",
        30 => x"0444444444",
        31 => x"0421084210",
        32 => x"0400000000",
        33 => x"03E0F83E0F",
        34 => x"03C3C3C3C3",
        35 => x"03A83A83A8",
        36 => x"038E38E38E",
        37 => x"03759F2298",
        38 => x"035E50D794",
        39 => x"0348348348",
        40 => x"0333333333",
        41 => x"031F3831F3",
        42 => x"030C30C30C",
        43 => x"02FA0BE82F",
        44 => x"02E8BA2E8B",
        45 => x"02D82D82D8",
        46 => x"02C8590B21",
        47 => x"02B9310572",
        48 => x"02AAAAAAAA",
        49 => x"029CBC14E5",
        50 => x"028F5C28F5",
        51 => x"0282828282",
        52 => x"0276276276",
        53 => x"026A439F65",
        54 => x"025ED097B4",
        55 => x"0253C8253C",
        56 => x"0249249249",
        57 => x"023EE08FB8",
        58 => x"0234F72C23",
        59 => x"022B63CBEE",
        60 => x"0222222222",
        61 => x"02192E29F7",
        62 => x"0210842108",
        63 => x"0208208208",
        64 => x"0200000000"
    );

begin

    process(all)

        variable span_v          : unsigned(32 downto 0);

        variable c0_eff          : unsigned(5 downto 0);
        variable c1_eff          : unsigned(5 downto 0);
        variable total_v         : unsigned(6 downto 0);


        -- Exact numerator, retained for final correction.
        variable numerator_v :
            unsigned(38 downto 0);

        -- Existing floor(2^39 / total) reciprocal.
        variable recip_v :
            unsigned(39 downto 0);

        -- c0 * reciprocal: 6 x 40.
        variable coeff_product_v :
            unsigned(45 downto 0);

        -- Approximate scaled probability coefficient:
        --
        -- floor(c0 * RECIP / 2^6)
        --
        -- Reachable contexts guarantee this fits in 33 bits.
        variable ratio_v :
            unsigned(32 downto 0);

        -- span * ratio: 33 x 33.
        variable ratio_product_v :
            unsigned(65 downto 0);

        variable q_est_v :
            unsigned(32 downto 0);

        -- Exact correction terms.
        variable qd_v :
            unsigned(39 downto 0);

        variable numerator40_v :
            unsigned(39 downto 0);

        variable remainder_v :
            unsigned(39 downto 0);

        variable total40_v :
            unsigned(39 downto 0);

        variable twice_total_v :
            unsigned(39 downto 0);

        variable q_corrected_v :
            unsigned(33 downto 0);

        variable split_v         : unsigned(32 downto 0);

    begin

        span_v  := high_in - low_in;
        split_v := to_unsigned(1, split_v'length);


        --------------------------------------------------------
        -- BYPASS
        --------------------------------------------------------

        if bypass_mode = '1' then

            split_v := shift_right(span_v, 1);


        --------------------------------------------------------
        -- REGULAR CONTEXT-CODED BIN
        --------------------------------------------------------

        else

            assert c0_in(6) = '0'
                report "recip_impl: c0 exceeds 6-bit range"
                severity failure;

            assert c1_in(6) = '0'
                report "recip_impl: c1 exceeds 6-bit range"
                severity failure;


            c0_eff := c0_in(5 downto 0);
            c1_eff := c1_in(5 downto 0);


            total_v :=
                resize(c0_eff, total_v'length) +
                resize(c1_eff, total_v'length);


            ----------------------------------------------------
            -- Reachable Context_step state
            ----------------------------------------------------

            if (c0_eff >= 1) and
               (c1_eff >= 1) and
               (total_v >= 2) and
               (total_v <= 64) then



                ------------------------------------------------
                -- Exact numerator retained only for correction:
                --
                -- N = span * c0
                ------------------------------------------------

                numerator_v :=
                    span_v * c0_eff;


                ------------------------------------------------
                -- Existing reciprocal:
                --
                -- R = floor(2^39 / total)
                ------------------------------------------------

                recip_v :=
                    RECIP_TABLE(to_integer(total_v));


                ------------------------------------------------
                -- Build a narrow combined ratio coefficient.
                --
                -- coeff_product = c0 * R
                --
                -- ratio =
                --     floor(coeff_product / 2^6)
                --
                -- This approximates:
                --
                --     floor(2^33 * c0 / total)
                ------------------------------------------------

                coeff_product_v :=
                    c0_eff * recip_v;


                -- For reachable c0 < total, coeff_product < 2^39.
                assert coeff_product_v(45 downto 39) = 0
                    report "ratio33: coefficient exceeds 39 bits"
                    severity failure;


                ratio_v :=
                    coeff_product_v(38 downto 6);


                ------------------------------------------------
                -- Quotient estimate using only a 33 x 33
                -- multiplication.
                ------------------------------------------------

                ratio_product_v :=
                    span_v * ratio_v;


                q_est_v :=
                    ratio_product_v(65 downto 33);


                ------------------------------------------------
                -- Exact correction.
                --
                -- With the ratio construction above, q_est can
                -- be at most TWO below the exact quotient.
                ------------------------------------------------

                qd_v :=
                    q_est_v * total_v;


                numerator40_v :=
                    resize(
                        numerator_v,
                        numerator40_v'length
                    );


                remainder_v :=
                    numerator40_v - qd_v;


                total40_v :=
                    resize(
                        total_v,
                        total40_v'length
                    );


                twice_total_v :=
                    shift_left(total40_v, 1);


                if remainder_v >= twice_total_v then

                    q_corrected_v :=
                        resize(
                            q_est_v,
                            q_corrected_v'length
                        ) + 2;


                elsif remainder_v >= total40_v then

                    q_corrected_v :=
                        resize(
                            q_est_v,
                            q_corrected_v'length
                        ) + 1;


                else

                    q_corrected_v :=
                        resize(
                            q_est_v,
                            q_corrected_v'length
                        );

                end if;


                split_v :=
                    q_corrected_v(32 downto 0);

            ----------------------------------------------------
            -- Invalid/unreachable context protection.
            ----------------------------------------------------

            else

                split_v :=
                    to_unsigned(1, split_v'length);

            end if;

        end if;


        --------------------------------------------------------
        -- Same zero-width protection as original.
        --------------------------------------------------------

        if split_v = 0 then
            split_v := to_unsigned(1, split_v'length);
        end if;


        split_out <= split_v;

    end process;

end architecture;
