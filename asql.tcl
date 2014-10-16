# asql.tcl
# Paul Walton
# Abstraction of SQL to more conveniently use relational databases.
# Currently requires sqlite3
#
# To do: 
#    foreign keys
#    groupby
#    transactions
#    joins
#    tdbc
#    auto-defining tables when loading an existing database file
#    tclOO?
#
# BUG: 'val' is a reserved variable in the uplevel'd scope. Name it something uncommon.
#
# Usage:
#   asql init ?filename?
#   asql define <table> {
#       <column name>  <type affinity>  ?#<comments>...?
#       ?...?
#   }
#   asql hook <command>
#   <table>::add  <dict of column names and values>
#   <table>::mod  ?-rowid <row ID>?  ?-expr {<expression>}?  <dict of column names and values>
#   <table>::del  ?-rowid <row ID>?  ?-expr {<expression>}?
#   <table>::del  *
#   <table>::get  <list of column names>  ?-rowid <row ID>?  ?-format (list|dict)?  ?-expr {<expression>}?  ?-order(:asc|:desc) <column>?  ?-limit (none|<integer>)?
#  New:
#   <table>::mod+  ... 
#   <table>::cols
#
# Examples:
#    # Initialize the database. 
#    # Optionally, provide a filename as an argument to save the database to disk or to use an existing database file.
#    # With no argument, the database will be stored in memory.
#    asql init
#
#   # Optionally set a callback command for all row insertions, updates, and deletes.
#   asql hook {puts "operation=%o, table=%t, rowid=%r"}
#
#    # A table must first be defined. If the table does not exist in the database then one is created.
#    # Comments may be appended to each line.
#    asql define car {
#        make    text                    # The make of the car.
#        model   text                    
#        year    integer                 
#        color   "text collate nocase"   # This column is case-insensitive. 
#    }
#    
#    # Add a couple of cars to the database.
#    car::add {
#        make   Ford  
#        model  Ranger
#        year   1996
#        color  tan
#    }
#    car::add [list make "Chevrolet"  model "Camaro"  year 1967  color burgandy]
#    car::add [list make "Ford"  model "Thunderbird"  year 2004  color black]
#     
#    # Get the color of the Ranger.
#    car::get color -expr {model="Ranger" && make="Ford"}
#    
#    # Use a variable and the 'like' operator (case-insensitive) to return all column values for the camaro.
#    # Expressions are injection-safe.
#    set model "camaro"
#    car::get * -expr {model~=$model}
#    
#    # Return all column values, plus the row ID, of the first object.
#    car::get {rowid *} -rowid 1
#    
#    # Modify the model name of the ranger.
#    car::mod -rowid 1 {model "Ranger XL"}
#    
#    # Return the make and model of all objects, ordered by year. The limit is 1 by default. Todo: Change limit to none by default.
#    car::get {make model}  -limit none  -order:desc year
#
#    # Return the highest year, the sum of all years, and the rowid of the last added row.
#    car::get max(year)
#    car::get sum(year)
#    car::get last_insert_rowid()
#    
#    # Delete the Camaro.
#    car::del -rowid 2
#    
#    # Delete the thunderbird.
#    car::del -expr {model="Thunderbird"}
#    
#    # Delete all cars.
#    car::del *
#
#    # Primary key:
#    asql define abc {
#        a   "integer primary key"
#        b   text
#        c   blob
#    }
#
#    # Composite primary key:
#    asql define xyz {
#        x   integer
#        y   text
#        z   integer
#        "primary key"   "(x, y)"
#    }
#
#

namespace eval asql {
    namespace ensemble create -subcommands {
        init
        define
        hook
    }
    
    # The sqlite3 database command token.
    variable token ""
    
    # The update hook callback.
    variable callback ""
    
    
    # Initialize the database. Create an in-memory database or optionally use a specified filename.
    proc init {{filename ":memory:"}} {
        package require sqlite3
        variable token "asql_db"
        sqlite3 $token $filename
        $token update_hook [namespace current]::fire_callback
        return
    }
    
    
    # Defines a table.
    proc define {table columns} {
        variable token
        if { $token eq "" } {
            error "no database token has been initialized"
        }
        
        # Create the table in the database if it does not already exist.
        create_table $table $columns
    
        # Create an eponymous namespace with pre-defined procedures.
        namespace eval ::$table {
            proc add  {values}    {asql::operation add [namespace tail [namespace current]] $values}
            proc del  {args}      {asql::operation del [namespace tail [namespace current]] {*}$args}
            proc mod  {args}      {asql::operation mod [namespace tail [namespace current]] {*}$args}
            proc mod+ {args}      {asql::operation mod+ [namespace tail [namespace current]] {*}$args}
            proc get  {cols args} {asql::operation get [namespace tail [namespace current]] $cols {*}$args}
            proc cols {}          {asql::operation cols [namespace tail [namespace current]]}
        }

        return
    }
    
    # Set the callback command for updates to the database.
    # The following substitutions will be made:
    #   %%  =  %
    #   %o  =  insert|update|delete|delete_all
    #   %t  =  <table>
    #   %r  =  <rowid>
    # If all rows of a table are deleted with '<table>::del *', then %o='delete_all' and %r=''.
    proc hook {command} {
        variable token
        if { $token eq "" } {
            error "no database token has been initialized"
        }
        variable callback $command
        return
    }
    
    # Fire the update hook callback.
    proc fire_callback {operation db_name table rowid} {
        variable callback
        if { $callback eq "" } {
            return
        }

        set operation [string tolower $operation]
        namespace eval :: [string map [list  %% %  %o $operation  %t $table  %r $rowid]  $callback]

        return
    }

    # Run an asql operation.
    proc operation {op table args} {
        variable token

        # The sql will typically be evaluated at the calling stack level.
        set level [uplevel 2 {info level}]
        
        # Generate a sql statement.
        switch -- $op {
            add  { set result [add_record  $level $table [lindex $args 0]] }
            del  { set result [del_records $level $table {*}$args] }
            mod  { set result [mod_records $level $table {*}$args] }
            mod+ { set result [mod+_records $level $table {*}$args] }
            get  { set result [get_records $level $table [lindex $args 0] {*}[lrange $args 1 end]] }
            cols { set result [lmap {x col x x x x} [$token eval "PRAGMA table_info($table)"] {list $col}] }
        }
        
        # Delete any generated variables.
        clear_variables
        
        # Return the result of the operation.
        return $result
    }
    
    # Evaluate a SQL statement.
    proc eval_sql {level statement {format "list"}} {
        variable token

        if { $format eq "list" } {
            return [uplevel "#$level" [list $token eval $statement] ]
        } elseif { $format eq "dict" } {
            return [uplevel "#$level" [list $token eval $statement val {
                set result [list]
                foreach col $val(*) {
                    dict set result $col $val($col)
                }
                return $result
            } ]]
        } else {
            error "invalid format '$format'; must be 'list' or 'dict'"
        }
    }
    
    
    # Add a record to a table. Values should be a paired list of column names and values.
    proc add_record {level table values} {
        return [eval_sql $level "INSERT INTO $table [clause_values $values]"]
    }
    

    # Delete zero or more records from a table.
    proc del_records {level table args} {
        if { "*" in $args } {
            if { [llength $args] != 1 } {
                error "when deleting all rows with '<table>::del *', no other arguments may be present."
            }
            # Delete all rows from the table.
            set result [eval_sql $level "DELETE FROM $table"]
            fire_callback delete_all "" $table -1
            return $result
        } else {
            set where [clause_where {*}$args]
            if { [string trim $where] eq "" } {
                error "must provide argument(s) to '<table>::del' : either '*', or '-expr <expression>' and/or '-rowid <id>'"
            }
            return [eval_sql $level "DELETE FROM $table [clause_where {*}$args]"]
        }
    }
    
    
    # Modify zero or more records in a table.
    proc mod_records {level table args} {
        return [eval_sql $level "UPDATE $table [clause_set [lindex $args end]] [clause_where {*}[lrange $args 0 end-1]]"]
    }
    

    # Modify 1 or more records in a table, or add a new record if no records match the WHERE clause (ie., -expr option).
    proc mod+_records {level table args} {
        if { [get_records $level $table count() {*}[lrange $args 0 end-1]] } {
            return [mod_records $level $table {*}$args]
        } else {
            return [add_record $level $table [lindex $args end]]
        }
    }


    # Retrieve zero or more records from a table.
    proc get_records {level table cols args} {
        # If an empty column list is given, use the asterisk.
        if { [llength $cols] == 0 } {
            set cols "*"
        }
        
        set where   [clause_where {*}$args]
        set orderby [clause_orderby {*}$args]
        set limit   [clause_limit {*}$args]

        # Evaluate the sql query.
        if { ![dict exists $args -format] } {
            dict set args -format list
        }
        set result [eval_sql $level "SELECT [join $cols {, }] from $table $where $orderby $limit"   [dict get $args -format]]
        
        # If exactly one column of one record has been requested with -format set to 'list', don't return the response as a list but as a single value.
        if {  [dict get $args -format] eq "list"  &&  [lindex $limit end] == 1  &&  [llength $cols] == 1  &&  $cols ne "*"  } {
            return [lindex $result 0]
        } else {
            return $result
        }
    }

    # Safely construct a VALUES clause that specifies columns and corresponding values.
    proc clause_values {dict} {
        # Create a list of column names and a list of column values.
        set names  [dict keys $dict]
        set values [list]
        foreach value [dict values $dict] {
            lappend values [variableize $value]
        }
        return "([join $names {, }]) VALUES ([join $values {, }])"
    }


    # Construct a WHERE clause, given a valid expression. Valid options are -rowid and -expr.
    proc clause_where {args} {
        # Construct an expression to go in the where clause.
        set expression ""
        
        # First, handle the -rowid option.
        if { [dict exists $args -rowid] } {
            if { [string is wideinteger -strict [dict get $args -rowid]] } {
                set expression "rowid = [dict get $args -rowid]"
            } else {
                set expression "rowid = ''"
            }
        }
        
        # Next, handle the -expr option.    
        if { [dict exists $args -expr]  &&  [dict get $args -expr] ne "" } {
            if { $expression ne "" } {
                set expression "$expression AND "
            }
            append expression [string map {~= { LIKE }  && { AND }  || { OR }}  [dict get $args -expr]]
        }
    
        # Return the where clause.
        if { $expression != "" } {
            return "WHERE $expression"
        }
        return
    }
    
    
    # Construct a SET clause that specifies columns and corresponding values.
    proc clause_set {dict} {
        # Create a list of column name and value assignments.
        set assignments ""
        dict for {name value} $dict {
            lappend assignments "$name = [variableize $value]"
        }
        return "SET [join $assignments {, }]"
    }
    
    
    # Construct an ORDER BY clause
    proc clause_orderby {args} {
        if { [dict exists $args -order]  &&  [dict get $args -order] != "" } {
            return "ORDER BY [dict get $args -order]"
        } elseif { [dict exists $args -order:asc]  &&  [dict get $args -order:asc] != ""  } {
            return "ORDER BY [dict get $args -order:asc] ASC"
        } elseif {  [dict exists $args -order:desc]  &&  [dict get $args -order:desc] != ""  } {
            return "ORDER BY [dict get $args -order:desc] DESC"
        }
        return
    }
    
    
    # Construct a LIMIT clause. The limit is 1 by default. Specify '-limit none' for no limit.
    proc clause_limit {args} {
        # Force use of limit=1 if '-format dict' is present.
        if { [dict exists $args -format]  &&  [dict get $args -format] eq "dict" } {
            return "LIMIT 1"
        }
    
        # Otherwise, set the limit based on the '-limit' option.
        if { [dict exists $args -limit]  &&  [dict get $args -limit] eq "none"  } {
            # Set an umlimited limit if '-limit none' is specified.
            return "LIMIT -1"

        } elseif { [dict exists $args -limit] } {
            return "LIMIT [dict get $args -limit]"
            
        } else {
            return "LIMIT 1"
        }
    }


    # Create a variable (with a random name) to store a value. Returns the fullpath variable name.
    proc variableize {value} {
        # Pick a random variable name.
        set name "[namespace current]::_temp_[string range [expr {rand()+1}] 2 end]"
        set $name $value
        return \$$name
    }


    # Delete all auto-generated variables.
    proc clear_variables {} {
        unset {*}[info vars [namespace current]::_temp_*]
        return
    }
    
    
    # Return boolean specifying if a table exists.
    proc table_exists {table} {
        variable token
        if { [$token eval "SELECT name FROM sqlite_master WHERE type='table' AND name='$table'"] == ""  } {
            return 0
        }
        return 1
    }
    
    
    # Create a new table if it does not already exist.
    proc create_table {table columns} {
        variable token
        set cols [list]
        foreach line [split $columns \n] {
            # Remove everything after and including the comment character on this line.
            set end [string first "#" $line]
            if { $end == -1 } {
                set end "end"
            }
            set line  [string range $line 0 $end]
            set name  [lindex $line 0]
            set type  [lindex $line 1]   
            if { $name != "" } {
                lappend cols "$name $type"
            }
        }

        # Only create the table if it doesn't already exist.
        if { ![table_exists $table] } {
            $token eval "CREATE TABLE $table ([join $cols {, }])"
        }
        return
    }

}

