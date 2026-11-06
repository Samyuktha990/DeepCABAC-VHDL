library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;

entity FIFO is
    generic (
        DATA_WIDTH : positive := 8;
        DEPTH      : positive := 32
    );
    port (
        clk      : in  std_logic;
        rst      : in  std_logic;

        wr_en    : in  std_logic;
        rd_en    : in  std_logic;

        data_in  : in  std_logic_vector(DATA_WIDTH-1 downto 0);
        data_out : out std_logic_vector(DATA_WIDTH-1 downto 0);

        rd_valid : out std_logic;
        full     : out std_logic;
        empty    : out std_logic;
        level    : out integer range 0 to DEPTH
    );
end entity;

architecture rtl of FIFO is
    type mem_array_t is array (0 to DEPTH-1)
        of std_logic_vector(DATA_WIDTH-1 downto 0);

    signal memory : mem_array_t;

    signal wr_ptr : integer range 0 to DEPTH-1 := 0;
    signal rd_ptr : integer range 0 to DEPTH-1 := 0;
    signal count  : integer range 0 to DEPTH   := 0;

begin

    full  <= '1' when count = DEPTH else '0';
    empty <= '1' when count = 0     else '0';
    level <= count;

    -- First-word-fall-through style output.
    -- data_out is valid whenever rd_valid='1'.
    rd_valid <= '1' when count > 0 else '0';
    data_out <= memory(rd_ptr) when count > 0 else (others => '0');

    process(clk)
        variable do_read  : boolean;
        variable do_write : boolean;
        variable next_wr  : integer range 0 to DEPTH-1;
        variable next_rd  : integer range 0 to DEPTH-1;
    begin
        if rising_edge(clk) then
            if rst = '1' then
                wr_ptr <= 0;
                rd_ptr <= 0;
                count  <= 0;

            else
                do_read := (rd_en = '1') and (count > 0);

                -- If the FIFO is full, a simultaneous read frees one slot,
                -- therefore the write is also accepted.
                do_write :=
                    (wr_en = '1') and
                    ((count < DEPTH) or do_read);

                assert not ((rd_en = '1') and (count = 0))
                    report "WARNING: read attempted while FIFO is EMPTY"
                    severity warning;

                assert not (
                    (wr_en = '1') and
                    (count = DEPTH) and
                    (not do_read)
                )
                    report "WARNING: write attempted while FIFO is FULL"
                    severity warning;

                next_wr := wr_ptr;
                next_rd := rd_ptr;

                if do_write then
                    memory(wr_ptr) <= data_in;

                    if wr_ptr = DEPTH-1 then
                        next_wr := 0;
                    else
                        next_wr := wr_ptr + 1;
                    end if;

                    wr_ptr <= next_wr;
                end if;

                if do_read then
                    if rd_ptr = DEPTH-1 then
                        next_rd := 0;
                    else
                        next_rd := rd_ptr + 1;
                    end if;

                    rd_ptr <= next_rd;
                end if;

                if do_write and (not do_read) then
                    count <= count + 1;
                elsif do_read and (not do_write) then
                    count <= count - 1;
                end if;
            end if;
        end if;
    end process;

end architecture;