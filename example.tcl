# Example usage of asql.tcl

# Initialize the database. No filename is given so it uses an in-memory database.
asql init

# Optionally set a callback command for all row insertions, updates, and deletes.
asql hook {puts "operation=%o, table=%t, rowid=%r"}

# A table must first be defined. If the table does not exist in the database then one is created.
# Comments may be appended to each line.
asql define car {
    make    text                    # The make of the car.
    model   text                    
    year    integer                 
    color   "text collate nocase"   # This column is case-insensitive. 
}

# Add a couple of cars to the database.
car::add {
    make   Ford  
    model  Ranger
    year   1996
    color  tan
}
car::add [list make "Chevrolet"  model "Camaro"  year 1967  color burgandy]
car::add [list make "Ford"  model "Thunderbird"  year 2004  color black]
 
# Get the color of the Ranger.
car::get color -expr {model="Ranger" && make="Ford"}

# Use a variable and the 'like' operator (case-insensitive) to return all column values for the camaro.
# Expressions are injection-safe.
set model "camaro"
car::get * -expr {model~=$model}

# Return all column values, plus the row ID, of the first object.
car::get {rowid *} -rowid 1

# Modify the model name of the ranger.
car::mod -rowid 1 {model "Ranger XL"}

# Return the make and model of all objects, ordered by year. The limit is 1 by default. Todo: Change limit to none by default.
car::get {make model}  -limit none  -order:desc year

# Return the highest year, the sum of all years, and the rowid of the last added row.
car::get max(year)
car::get sum(year)
car::get last_insert_rowid()

# Delete the Camaro.
car::del -rowid 2

# Delete the thunderbird.
car::del -expr {model="Thunderbird"}

# Delete all cars.
car::del *

# Define a table with a primary key:
asql define abc {
    a   "integer primary key"
    b   text
    c   blob
}

# Define a table with a composite primary key:
asql define xyz {
    x   integer
    y   text
    z   integer
    "primary key"   "(x, y)"
}