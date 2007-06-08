(*pp derivingpp *)

module Bounded_bool : Bounded.Bounded with type a = bool
module Enum_bool : Enum.Enum with type a = bool
module Show_bool : Show.Show with type a = bool
module Bounded_char : Bounded.Bounded with type a = char
module Enum_char : Enum.Enum with type a = char
module Show_char : Show.Show with type a = char
module Bounded_int : Bounded.Bounded with type a = int
module Enum_int : Enum.Enum with type a = int
module Show_int : Show.Show with type a = int
module Show_num : Show.Show with type a = Num.num
module Show_float : Show.Show with type a = float
module Show_string : Show.Show with type a = string
module Bounded_unit : Bounded.Bounded with type a = unit
module Enum_unit : Enum.Enum with type a = unit
module Show_unit : Show.Show with type a = unit

type open_flag = Pervasives.open_flag
    deriving (Typeable, Show, Eq, Enum, Bounded, Pickle)

type fpclass = Pervasives.fpclass
    deriving (Typeable, Show, Eq, Enum, Bounded, Pickle)

type 'a ref = 'a Pervasives.ref
    deriving (Typeable, Show, Eq)
