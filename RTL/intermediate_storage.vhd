library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;

entity intermediate_storage is
    generic (
        RESERVOIR_WIDTH : positive := 16
    );
    port (
        clk             : in  std_logic;
        rst             : in  std_logic;

        -- FWFT FIFO: fifo_data_out is the current head byte whenever
        -- fifo_rd_valid = '1'. A read removes that byte at rising_edge(clk).
        fifo_data_out   : in  std_logic_vector(7 downto 0);
        fifo_rd_valid   : in  std_logic;
        fifo_rd_en      : out std_logic;

        -- Serial bit consumption for arithmetic decoder initialization.
        bit_consume     : in  std_logic;
        bit_out         : out std_logic;
        bit_valid       : out std_logic;

        -- Parallel bit consumption for a successfully decoded symbol.
        consume_count   : in  natural range 0 to RESERVOIR_WIDTH;
        bits_out        : out std_logic_vector(RESERVOIR_WIDTH-1 downto 0);
        valid_bits      : out natural range 0 to RESERVOIR_WIDTH
    );
end entity;

architecture rtl of intermediate_storage is
    signal buffer_reg : std_logic_vector(RESERVOIR_WIDTH-1 downto 0)
        := (others => '0');
    signal bit_count  : natural range 0 to RESERVOIR_WIDTH := 0;
    signal fifo_take  : std_logic;
begin
    assert RESERVOIR_WIDTH >= 8
        report "Intermediate storage must be at least 8 bits wide"
        severity failure;

    bits_out   <= buffer_reg;
    valid_bits <= bit_count;
    bit_out    <= buffer_reg(RESERVOIR_WIDTH-1);
    bit_valid  <= '1' when bit_count > 0 else '0';

    -- IMPORTANT: Read control depends only on registered occupancy and
    -- FIFO availability, NOT on consume_count (which comes from the
    -- combinational CABAC decoder). This avoids a combinational loop.
    -- At most one 8-bit FIFO byte is accepted per clock.
    fifo_take <= '1' when
        rst = '0' and
        fifo_rd_valid = '1' and
        bit_count <= RESERVOIR_WIDTH - 8
        else '0';

    fifo_rd_en <= fifo_take;

    process(clk)
        variable next_buffer : std_logic_vector(RESERVOIR_WIDTH-1 downto 0);
        variable next_count  : natural range 0 to RESERVOIR_WIDTH;
        variable nconsume    : natural range 0 to RESERVOIR_WIDTH;
    begin
        if rising_edge(clk) then
            if rst = '1' then
                buffer_reg <= (others => '0');
                bit_count  <= 0;
            else
                next_buffer := buffer_reg;
                next_count  := bit_count;
                nconsume    := 0;

                -- Initialization has priority if both requests are asserted.
                if bit_consume = '1' then
                    if next_count > 0 then
                        nconsume := 1;
                    end if;
                elsif consume_count > 0 then
                    assert consume_count <= next_count
                        report "Reservoir consumption exceeds available bits"
                        severity failure;
                    if consume_count <= next_count then
                        nconsume := consume_count;
                    end if;
                end if;

                -- Consume bits from the MSB end. The next unread bit
                -- becomes buffer_reg(RESERVOIR_WIDTH-1).
                if nconsume > 0 then
                    if nconsume = RESERVOIR_WIDTH then
                        next_buffer := (others => '0');
                    else
                        next_buffer := std_logic_vector(
                            shift_left(unsigned(next_buffer), nconsume));
                    end if;
                    next_count := next_count - nconsume;
                end if;

                -- Append one FIFO byte after the remaining valid bits.
                -- Can happen in the same cycle as consumption.
                if fifo_take = '1' then
                    assert next_count <= RESERVOIR_WIDTH - 8
                        report "FIFO append would overflow reservoir"
                        severity failure;
                    if next_count <= RESERVOIR_WIDTH - 8 then
                        for i in 0 to 7 loop
                            next_buffer(RESERVOIR_WIDTH-1-next_count-i)
                                := fifo_data_out(7-i);
                        end loop;
                        next_count := next_count + 8;
                    end if;
                end if;

                buffer_reg <= next_buffer;
                bit_count  <= next_count;
            end if;
        end if;
    end process;
end architecture;