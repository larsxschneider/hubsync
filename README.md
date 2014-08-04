hubsync
=======

Syncs all repositories of a user/organization on github.com to a user/organization of a GitHub Enterprise instance.

## Installation

    gem install bundler
    bundle install


## Usage

    ./hubsync.rb <github.com organization>        \
                 <github.com access-token>        \
                 <github enterprise url>          \
                 <github enterprise organization> \
                 <github enterprise token>        \
                 <repository-cache-path>

## License

hubsync is available under the MIT license. See the LICENSE file for more info.
